#!/bin/bash
# Xray balancer dashboard. Live full-screen view of leastLoad pools
# from remnanode /debug/vars (port 11111). One shot if stdout is not a tty:
#   ./balancer.sh --once
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required" >&2
    exit 1
fi
exec python3 -u - "$@" << 'PY'
import curses
import json
import locale
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time

try:
    locale.setlocale(locale.LC_ALL, "")
except locale.Error:
    pass
from dataclasses import dataclass, field

CONTAINER = os.environ.get("BALANCER_CONTAINER", "remnanode")
DEFAULT_INTERVAL = float(os.environ.get("BALANCER_INTERVAL", "2"))
SUDO = [] if os.geteuid() == 0 else ["sudo"]

_DUR = re.compile(r"^\s*([0-9]*\.?[0-9]+)\s*(ns|us|µs|μs|ms|s|m|h)\s*$")
_UNIT_NS = {
    "ns": 1,
    "us": 1_000,
    "µs": 1_000,
    "μs": 1_000,
    "ms": 1_000_000,
    "s": 1_000_000_000,
    "m": 60_000_000_000,
    "h": 3_600_000_000_000,
}


def duration_ns(value):
    if value is None or value is False:
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    text = str(value).strip()
    if not text or text == "0":
        return 0
    match = _DUR.match(text)
    if not match:
        return 0
    return int(float(match.group(1)) * _UNIT_NS[match.group(2)])


def duration_ms_trunc(value):
    """Match Go time.Duration.Milliseconds, used by leastLoad maxRTT."""
    return duration_ns(value) // 1_000_000


def parse_json_blob(raw):
    text = raw.decode("utf-8", "replace")
    start = text.find("{")
    if start < 0:
        raise ValueError("json object not found")
    obj, _ = json.JSONDecoder().raw_decode(text[start:])
    return obj


def run(cmd, timeout=8):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise TimeoutError(" ".join(cmd[:4]))
    return out, err, proc.returncode


def fetch():
    pid_out, pid_err, rc = run(
        SUDO + ["docker", "inspect", "--format", "{{.State.Pid}}", CONTAINER],
        timeout=5,
    )
    if rc != 0 or not pid_out.strip():
        detail = (pid_err or pid_out).decode("utf-8", "replace").strip()
        raise RuntimeError(detail or f"container {CONTAINER} is not running")
    pid = pid_out.decode().strip()
    cfg_proc = subprocess.Popen(
        SUDO + ["docker", "exec", CONTAINER, "cli", "--dump-config"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    met_proc = subprocess.Popen(
        SUDO
        + [
            "nsenter",
            "-t",
            pid,
            "-n",
            "curl",
            "-sS",
            "--max-time",
            "5",
            "http://127.0.0.1:11111/debug/vars",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        cfg_out, _ = cfg_proc.communicate(timeout=8)
        met_out, met_err = met_proc.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        cfg_proc.kill()
        met_proc.kill()
        cfg_proc.communicate()
        met_proc.communicate()
        raise TimeoutError("config or /debug/vars timed out")
    if cfg_proc.returncode != 0:
        raise RuntimeError("cli --dump-config failed")
    if met_proc.returncode != 0:
        detail = met_err.decode("utf-8", "replace").strip()
        raise RuntimeError(detail or "/debug/vars request failed")
    return parse_json_blob(cfg_out), parse_json_blob(met_out)


@dataclass
class Obs:
    alive: bool
    delay_ms: int
    samples: int
    fail: int
    dev_ns: int
    avg_ns: int
    min_ns: int
    max_ns: int
    has_ping: bool


@dataclass
class Row:
    tag: str
    status: str
    obs: Obs | None
    cost: float
    score: int


@dataclass
class Pool:
    name: str
    selectors: list
    strategy: str
    max_rtt: str
    max_rtt_ms: int
    expected: int
    baselines: list
    baseline_ns: list
    tolerance: float
    costs: list
    rows: list = field(default_factory=list)
    selected: list = field(default_factory=list)


def cost_for(tag, rules):
    for is_regexp, pattern, value in rules:
        if is_regexp:
            try:
                matched = re.search(pattern, tag)
            except re.error:
                continue
            if not matched:
                continue
            found = matched.group(0)
        else:
            if pattern not in tag:
                continue
            found = pattern
        if value > 0:
            return float(value)
        number = re.search(r"\d+(\.\d+)?", found)
        return float(number.group(0)) if number else 1.0
    return 1.0


def qualify(obs, max_rtt_ms, tolerance):
    if obs is None:
        return "NODATA"
    if not obs.alive:
        return "DEAD"
    if max_rtt_ms and obs.delay_ms >= max_rtt_ms:
        return "RTT"
    if obs.samples > 0 and tolerance > 0 and (obs.fail / obs.samples) > tolerance:
        return "FAIL"
    return ""


def node_score(obs, cost):
    """leastLoad sorts by cost-adjusted stdev, matching time.Duration truncation."""
    if obs.has_ping:
        base = obs.dev_ns
    else:
        base = obs.delay_ms * 1_000_000
    return int(base * math.sqrt(cost))


def sort_key(row):
    obs = row.obs
    avg = obs.avg_ns if obs and obs.has_ping else (obs.delay_ms * 1_000_000 if obs else 0)
    fail = obs.fail if obs else 1
    samples = obs.samples if obs else 0
    return (row.score, avg, fail, -samples, row.tag)


def select_least_load(qualified, expected, baseline_ns):
    if not qualified:
        return []
    if expected > len(qualified):
        return qualified[:]
    want = expected if expected > 0 else 1
    if not baseline_ns:
        return qualified[:want]
    count = 0
    for baseline in baseline_ns:
        index = count
        while index < len(qualified):
            if qualified[index].score >= baseline:
                break
            count = index + 1
            index += 1
        if count >= want:
            break
    if expected > 0 and count < want:
        count = want
    return qualified[:count]


def build(config, metrics):
    observatory = metrics.get("observatory") or {}
    observations = {}
    for key, value in observatory.items():
        if not isinstance(value, dict):
            continue
        ping = value.get("health_ping") or {}
        tag = value.get("outbound_tag") or key
        observations[tag] = Obs(
            alive=bool(value.get("alive")),
            delay_ms=int(value.get("delay") or 0),
            samples=int(ping.get("all") or 0),
            fail=int(ping.get("fail") or 0),
            dev_ns=int(ping.get("deviation") or 0),
            avg_ns=int(ping.get("average") or 0),
            min_ns=int(ping.get("min") or 0),
            max_ns=int(ping.get("max") or 0),
            has_ping=bool(ping),
        )

    outbound_tags = []
    for outbound in config.get("outbounds") or []:
        tag = outbound.get("tag")
        if tag:
            outbound_tags.append(tag)

    probe = ""
    burst = config.get("burstObservatory") or config.get("observatory") or {}
    ping_cfg = burst.get("pingConfig") or {}
    if ping_cfg.get("interval"):
        probe = str(ping_cfg["interval"])

    pools = []
    for balancer in (config.get("routing") or {}).get("balancers") or []:
        settings = (balancer.get("strategy") or {}).get("settings") or {}
        selectors = [str(item) for item in (balancer.get("selector") or [])]
        costs = []
        for rule in settings.get("costs") or []:
            costs.append(
                (
                    bool(rule.get("regexp")),
                    str(rule.get("match") or ""),
                    float(rule.get("value") or 0),
                )
            )
        baselines = [str(item) for item in (settings.get("baselines") or [])]
        pool = Pool(
            name=str(balancer.get("tag") or "?"),
            selectors=selectors,
            strategy=str((balancer.get("strategy") or {}).get("type") or "leastLoad"),
            max_rtt=str(settings.get("maxRTT") or "0s"),
            max_rtt_ms=duration_ms_trunc(settings.get("maxRTT")),
            expected=int(settings.get("expected") or 0),
            baselines=baselines,
            baseline_ns=[duration_ns(item) for item in baselines],
            tolerance=float(settings.get("tolerance") or 0),
            costs=costs,
        )
        seen = set()
        tags = []
        for tag in outbound_tags:
            if tag in seen:
                continue
            if any(tag.startswith(prefix) for prefix in selectors):
                seen.add(tag)
                tags.append(tag)
        for tag in observations:
            if tag not in seen and any(tag.startswith(prefix) for prefix in selectors):
                seen.add(tag)
                tags.append(tag)

        qualified = []
        rejected = []
        for tag in tags:
            obs = observations.get(tag)
            cost = cost_for(tag, costs)
            reason = qualify(obs, pool.max_rtt_ms, pool.tolerance)
            score = node_score(obs, cost) if obs else 0
            row = Row(tag, reason or "RANK", obs, cost, score)
            if reason:
                rejected.append(row)
            else:
                qualified.append(row)
        qualified.sort(key=sort_key)
        if pool.strategy == "leastLoad":
            chosen = select_least_load(qualified, pool.expected, pool.baseline_ns)
        else:
            chosen = qualified[:]
        chosen_tags = {row.tag for row in chosen}
        for row in qualified:
            row.status = "IN" if row.tag in chosen_tags else "RANK"
        reject_order = {"RTT": 0, "FAIL": 1, "DEAD": 2, "NODATA": 3}
        rejected.sort(key=lambda row: (reject_order.get(row.status, 9), row.tag))
        pool.rows = qualified + rejected
        pool.selected = [row.tag for row in chosen]
        pools.append(pool)
    return pools, probe, len(observations)


ATTR = {}

ANSI = {
    "row_in": "\033[1;32m",
    "row_idle": "\033[37m",
    "row_bad": "\033[38;5;130m",
    "band20": "\033[1;34m",
    "band40": "\033[1;32m",
    "band50": "\033[1;33m",
    "band70": "\033[38;5;208m",
    "band90": "\033[1;31m",
    "band100": "\033[38;5;130m",
    "col": "\033[2m",
    "ok": "\033[1;36m",
    "pool": "\033[1;32m",
}
ANSI_RESET = "\033[0m"

EXT_COLOR = {
    "blue": 33,
    "green": 34,
    "yellow": 220,
    "orange": 208,
    "red": 196,
    "brown": 130,
    "white": 255,
}
BASIC_COLOR = {
    "blue": curses.COLOR_BLUE,
    "green": curses.COLOR_GREEN,
    "yellow": curses.COLOR_YELLOW,
    "orange": curses.COLOR_YELLOW,
    "red": curses.COLOR_RED,
    "brown": curses.COLOR_RED,
    "white": curses.COLOR_WHITE,
}


def setup_colors(bg):
    use_ext = curses.COLORS >= 256
    palette = EXT_COLOR if use_ext else BASIC_COLOR

    def fg(name):
        return palette[name]

    pairs = {
        10: "blue",
        11: "green",
        12: "yellow",
        13: "orange",
        14: "red",
        15: "brown",
        16: "white",
    }
    for number, name in pairs.items():
        try:
            curses.init_pair(number, fg(name), bg)
        except curses.error:
            curses.init_pair(number, BASIC_COLOR[name], bg)
    bold = curses.A_BOLD
    ATTR.clear()
    ATTR.update(
        {
            "band20": curses.color_pair(10) | bold,
            "band40": curses.color_pair(11) | bold,
            "band50": curses.color_pair(12) | bold,
            "band70": curses.color_pair(13) | bold,
            "band90": curses.color_pair(14) | bold,
            "band100": curses.color_pair(15) | bold,
            "row_in": curses.color_pair(11) | bold,
            "row_idle": curses.color_pair(16),
            "row_bad": curses.color_pair(15),
            "pool": curses.color_pair(11) | bold,
            "col": curses.A_DIM,
            "ok": curses.color_pair(6) | bold,
            "warn": curses.color_pair(8) | bold,
            "bad": curses.color_pair(7) | bold,
            "gap": 0,
        }
    )


def fmt_ms(ns):
    value = ns / 1_000_000
    if value >= 100:
        return f"{value:7.1f}"
    return f"{value:7.2f}"


def fmt_rtt(obs):
    if obs is None:
        return "      -"
    return f"{obs.delay_ms:7d}"


FIELD_W = {"rtt": 7, "stdev": 7, "avg": 7, "min": 7, "max": 7, "n": 3, "cost": 5}


def visible_fields(width):
    # Keep RTT and STDEV. Add the rest only while the row still fits.
    fields = ["rtt", "stdev"]
    used = 1 + 12 + 1 + 4 + 1 + 7 + 1 + 7
    for name in ("avg", "min", "max", "n", "cost"):
        if used + 1 + FIELD_W[name] <= width - 1:
            fields.append(name)
            used += 1 + FIELD_W[name]
    return fields


def pool_mark(status):
    if status == "IN":
        return "✓", "row_in"
    if status in ("DEAD", "NODATA", "FAIL", "RTT"):
        return "✗", "row_bad"
    return "○", "row_idle"


def rtt_band(delay_ms, max_rtt_ms):
    if max_rtt_ms <= 0:
        return "row_idle"
    ratio = delay_ms / max_rtt_ms
    if ratio <= 0.20:
        return "band20"
    if ratio <= 0.40:
        return "band40"
    if ratio <= 0.50:
        return "band50"
    if ratio <= 0.70:
        return "band70"
    if ratio < 1:
        return "band90"
    return "band100"


def metric_parts(row, fields):
    parts = []
    obs = row.obs
    if "stdev" in fields:
        parts.append(fmt_ms(obs.dev_ns) if obs and obs.has_ping else "      -")
    if "avg" in fields:
        parts.append(fmt_ms(obs.avg_ns) if obs and obs.has_ping else "      -")
    if "min" in fields:
        parts.append(fmt_ms(obs.min_ns) if obs and obs.has_ping else "      -")
    if "max" in fields:
        parts.append(fmt_ms(obs.max_ns) if obs and obs.has_ping else "      -")
    if "n" in fields:
        if obs is None:
            parts.append("  -")
        elif obs.fail:
            parts.append(f"{obs.samples}!".rjust(3))
        else:
            parts.append(f"{obs.samples:3d}")
    if "cost" in fields:
        parts.append(f"{row.cost:5.2f}" if row.cost != 1 else "    1")
    return parts


def tag_width(width, meta):
    return min(28, max(12, width - len(meta) - 4 - 4))


def row_segments(row, pool, width):
    mark, base = pool_mark(row.status)
    fields = visible_fields(width)
    rtt = fmt_rtt(row.obs) if "rtt" in fields else ""
    rest = " ".join(metric_parts(row, fields))
    meta = " ".join(part for part in (rtt, rest) if part)
    width_for_tag = tag_width(width, meta)
    tag = row.tag if len(row.tag) <= width_for_tag else row.tag[: width_for_tag - 1] + "…"
    segments = [(base, f" {tag:<{width_for_tag}} {mark:^4}")]
    if rtt:
        if row.status in ("DEAD", "NODATA", "FAIL"):
            band = "row_bad"
        elif row.obs is None:
            band = base
        else:
            band = rtt_band(row.obs.delay_ms, pool.max_rtt_ms)
        segments.append((band, " " + rtt))
    if rest:
        segments.append((base, " " + rest))
    return segments


def header_text(width):
    fields = visible_fields(width)
    labels = {
        "rtt": f"{'RTT':>7}",
        "stdev": f"{'STDEV':>7}",
        "avg": f"{'AVG':>7}",
        "min": f"{'MIN':>7}",
        "max": f"{'MAX':>7}",
        "n": f"{'N':>3}",
        "cost": f"{'COST':>5}",
    }
    meta = " ".join(labels[name] for name in fields)
    tag_w = tag_width(width, meta)
    return f" {'OUTBOUND':<{tag_w}} {'POOL':^4} {meta}"


def pool_banner(pool, width):
    selected = len(pool.selected)
    total = len(pool.rows)
    sel = ",".join(pool.selectors) if pool.selectors else "-"
    text = f" {pool.name}   sel={sel}   in pool {selected}/{total}   expected {pool.expected}"
    return text[: width - 1]


def settings_segments(pool, width):
    base = ",".join(pool.baselines) if pool.baselines else "-"
    segments = [("col", f" maxRTT {pool.max_rtt}   baseline {base}   ")]
    if pool.max_rtt_ms > 0:
        for ratio, style, label in (
            (0.20, "band20", "20%"),
            (0.40, "band40", "40%"),
            (0.50, "band50", "50%"),
            (0.70, "band70", "70%"),
            (0.90, "band90", "90%"),
            (1.00, "band100", "100%"),
        ):
            segments.append((style, f"{label} {int(pool.max_rtt_ms * ratio)}ms  "))
    return clip_segments(segments, width)


def render(pools, probe, obs_count, host, fetched_at, interval, error, width):
    alive = 0
    seen = set()
    for pool in pools:
        for row in pool.rows:
            if row.tag in seen or row.obs is None:
                continue
            seen.add(row.tag)
            if row.obs.alive:
                alive += 1
    now = time.strftime("%H:%M:%S")
    age = max(0, int(time.time() - fetched_at)) if fetched_at else -1
    age_s = f"{age}s" if age >= 0 else "…"
    head = (
        f" xray balancers  {host}  {now}  nodes {alive}/{obs_count} alive"
        f"  probe {probe or '-'}  refresh {interval:.1f}s  age {age_s}  unit=ms"
    )
    lines = []
    section_at = []
    for pool in pools:
        section_at.append(len(lines))
        if not pool.selected:
            kind = "bad"
        elif any(row.status == "DEAD" for row in pool.rows):
            kind = "warn"
        else:
            kind = "ok"
        lines.append((kind, pool_banner(pool, width).ljust(max(0, width - 1))))
        lines.append(("segs", settings_segments(pool, width)))
        lines.append(("col", header_text(width)))
        for row in pool.rows:
            lines.append(("segs", row_segments(row, pool, width)))
        lines.append(("gap", ""))
    if not lines and not error:
        lines.append(("col", " loading…"))
    return head, lines, section_at, error


def clip(text, width):
    if width <= 1:
        return ""
    if len(text) <= width - 1:
        return text
    if width <= 2:
        return text[: width - 1]
    return text[: width - 2] + "…"


def clip_segments(segments, width):
    limit = max(0, width - 1)
    kept = []
    used = 0
    for style, text in segments:
        room = limit - used
        if room <= 0:
            break
        if len(text) > room:
            kept.append((style, text[:room]))
            break
        kept.append((style, text))
        used += len(text)
    return kept


def paint(stdscr, view, offset):
    height, width = stdscr.getmaxyx()
    if height < 4 or width < 20:
        return 0
    stdscr.erase()
    head, lines, _section_at, error = view
    body_top = 1
    footer_y = height - 1
    body_h = max(1, footer_y - body_top)
    max_off = max(0, len(lines) - body_h)
    offset = min(max(0, offset), max_off)

    put(stdscr, 0, clip(head, width).ljust(width - 1), curses.A_REVERSE | curses.A_BOLD)
    for index in range(body_h):
        src = offset + index
        if src >= len(lines):
            break
        kind, payload = lines[src]
        if kind == "segs":
            put_segments(stdscr, body_top + index, payload, width)
        else:
            put(stdscr, body_top + index, clip(str(payload), width), ATTR.get(kind, 0))

    shown = min(len(lines), offset + body_h)
    extra = f"  {offset + 1}-{shown}/{len(lines)}" if len(lines) > body_h else ""
    err = f"  {error}" if error else ""
    foot = f" q quit  j/k scroll  [] pools  ✓ in pool  ○ idle  ✗ dead/maxrtt{extra}{err}"
    put(stdscr, footer_y, clip(foot, width).ljust(max(0, width - 1)), curses.A_REVERSE)
    stdscr.refresh()
    return offset


def put(stdscr, y, text, attr=0):
    height, width = stdscr.getmaxyx()
    if y < 0 or y >= height or width < 2:
        return
    try:
        stdscr.addnstr(y, 0, text, width - 1, attr)
    except curses.error:
        pass


def put_segments(stdscr, y, segments, width):
    height, screen_w = stdscr.getmaxyx()
    if y < 0 or y >= height or screen_w < 2:
        return
    x = 0
    limit = min(width, screen_w) - 1
    for style, text in segments:
        if x >= limit or not text:
            break
        chunk = text[: limit - x]
        try:
            stdscr.addnstr(y, x, chunk, len(chunk), ATTR.get(style, 0))
        except curses.error:
            break
        x += len(chunk)


def oneshot(interval):
    host = os.uname().nodename
    started = time.time()
    config, metrics = fetch()
    pools, probe, obs_count = build(config, metrics)
    width = 120
    try:
        width = max(80, os.get_terminal_size().columns)
    except OSError:
        pass
    head, lines, _sections, _error = render(
        pools, probe, obs_count, host, started, interval, "", width
    )
    print(head.rstrip())
    for kind, payload in lines:
        if kind == "segs":
            print("".join(ANSI.get(style, "") + text + ANSI_RESET for style, text in payload).rstrip())
        else:
            code = ANSI.get(kind, "")
            print(f"{code}{str(payload).rstrip()}{ANSI_RESET if code else ''}")


def live(interval):
    try:
        tty = os.open("/dev/tty", os.O_RDWR)
    except OSError:
        oneshot(interval)
        return
    os.dup2(tty, 0)
    os.dup2(tty, 1)
    os.dup2(tty, 2)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    curses.wrapper(lambda stdscr: ui(stdscr, interval))


def ui(stdscr, interval):
    curses.curs_set(0)
    curses.start_color()
    try:
        curses.use_default_colors()
        bg = -1
    except curses.error:
        bg = curses.COLOR_BLACK
    curses.init_pair(1, curses.COLOR_GREEN, bg)
    curses.init_pair(2, curses.COLOR_RED, bg)
    curses.init_pair(3, curses.COLOR_YELLOW, bg)
    curses.init_pair(4, curses.COLOR_CYAN, bg)
    curses.init_pair(5, curses.COLOR_MAGENTA, bg)
    curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(7, curses.COLOR_WHITE, curses.COLOR_RED)
    curses.init_pair(8, curses.COLOR_BLACK, curses.COLOR_YELLOW)
    setup_colors(bg)
    stdscr.keypad(True)
    stdscr.timeout(150)
    host = os.uname().nodename
    state = {
        "pools": [],
        "probe": "",
        "obs_count": 0,
        "fetched_at": 0,
        "error": "",
        "interval": interval,
        "stop": False,
    }
    lock = threading.Lock()
    wake = threading.Event()

    def worker():
        while True:
            with lock:
                if state["stop"]:
                    return
                current = state["interval"]
            started = time.time()
            try:
                config, metrics = fetch()
                pools, probe, obs_count = build(config, metrics)
                with lock:
                    if state["stop"]:
                        return
                    state["pools"] = pools
                    state["probe"] = probe
                    state["obs_count"] = obs_count
                    state["fetched_at"] = time.time()
                    state["error"] = ""
            except Exception as exc:
                with lock:
                    if state["stop"]:
                        return
                    state["error"] = str(exc)
            elapsed = time.time() - started
            if wake.wait(max(0.2, current - elapsed)):
                wake.clear()

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    offset = 0
    try:
        while True:
            height, width = stdscr.getmaxyx()
            with lock:
                view = render(
                    state["pools"],
                    state["probe"],
                    state["obs_count"],
                    host,
                    state["fetched_at"],
                    state["interval"],
                    state["error"],
                    width,
                )
                section_at = view[2]
            offset = paint(stdscr, view, offset)
            key = stdscr.getch()
            page = max(1, height - 3)
            if key in (ord("q"), ord("Q")):
                break
            elif key in (curses.KEY_UP, ord("k"), ord("K")):
                offset -= 1
            elif key in (curses.KEY_DOWN, ord("j"), ord("J")):
                offset += 1
            elif key in (curses.KEY_PPAGE, ord("u")):
                offset -= page
            elif key in (curses.KEY_NPAGE, ord(" "), ord("d")):
                offset += page
            elif key in (curses.KEY_HOME, ord("g")):
                offset = 0
            elif key in (curses.KEY_END, ord("G")):
                offset = 10**9
            elif key in (ord("]"), ord("\t"), curses.KEY_RIGHT):
                nxt = next((pos for pos in section_at if pos > offset + 1), None)
                if nxt is not None:
                    offset = nxt
            elif key in (ord("["), curses.KEY_LEFT):
                prev = [pos for pos in section_at if pos < offset]
                if prev:
                    offset = prev[-1]
            elif key in (ord("r"), ord("R")):
                wake.set()
            elif key in (ord("+"), ord("=")):
                with lock:
                    state["interval"] = min(30.0, round(state["interval"] + 0.5, 1))
                wake.set()
            elif key == ord("-"):
                with lock:
                    state["interval"] = max(0.5, round(state["interval"] - 0.5, 1))
                wake.set()
            elif key == curses.KEY_RESIZE:
                pass
    finally:
        with lock:
            state["stop"] = True
        wake.set()
        thread.join(timeout=2)


def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        print("usage: balancer.sh [--once]")
        print("live full-screen dashboard of Xray leastLoad pools")
        print("keys: q quit, j/k scroll, [] next/prev pool, r refresh, +/- interval")
        return
    interval = DEFAULT_INTERVAL
    if "--once" in sys.argv or not sys.stdout.isatty():
        oneshot(interval)
        return
    live(interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
PY
