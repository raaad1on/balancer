# Xray Balancer Analyzer (SRE Edition)

Живой дашборд балансировщиков Xray. Состав leastLoad-пула, RTT и stdev берутся из `/debug/vars`, без разбора логов.

## Быстрый старт

Нужен терминал (`ssh -t`). На хосте, где запущен контейнер `remnanode`:

```bash
curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash
```

Локально:

```bash
git clone https://github.com/raaad1on/balancer.git
cd balancer
chmod +x balancer.sh
sudo ./balancer.sh
```

Один кадр без полноэкранного режима (cron, пайп):

```bash
sudo ./balancer.sh --once
```

Клавиши: `q` выход, `j`/`k` прокрутка, `[` `]` соседний пул, `r` обновить, `+`/`-` интервал. По умолчанию обновление раз в 2 секунды (`BALANCER_INTERVAL`).

## Требования

- **Docker** — контейнер `remnanode`
- **python3** — интерфейс и разбор JSON
- **curl** — запрос `/debug/vars` с хоста через `nsenter`
- **sudo** — если скрипт запущен не от root

## Что показывает

Для каждого балансировщика из конфига:

- селекторы, `expected`, `maxRTT`, `baseline` и шкала 20/40/50/70/90/100% от `maxRTT`
- все аутбаунды пула: RTT, STDEV, AVG, MIN, MAX, число проб, cost

Цвет RTT — доля от `maxRTT` этого балансировщика: синий до 20%, зелёный до 40%, жёлтый до 50%, оранжевый до 70%, красный до 90%, коричневый от 100%.

Колонка `POOL`:

- `✓` — нода сейчас в leastLoad-пуле
- `○` — живая, но не выбрана
- `✗` — мёртвая или RTT не ниже `maxRTT`

Пул считается так же, как leastLoad в Xray: живые ноды с `delay < maxRTT`, сортировка по stdev с учётом `sqrt(cost)`, затем baseline и `expected`.

## Как работает

1. Конфиг снимается командой `docker exec remnanode cli --dump-config`.
2. Метрики читаются с хоста: `nsenter` в сеть контейнера и `curl http://127.0.0.1:11111/debug/vars`.
3. Кандидаты балансировщика — аутбаунды, чей тег начинается с одного из `selector`.
4. Логи Xray не читаются.

## Troubleshooting

| Ошибка | Решение |
|--------|---------|
| `python3 is required` | Поставить python3 |
| `container remnanode is not running` | `docker ps` |
| `cli --dump-config failed` | `docker logs remnanode` |
| `/debug/vars request failed` | Проверить, что порт 11111 отвечает внутри контейнера |
| Экран сразу печатает один кадр и выходит | Запускать в TTY: `ssh -t`, не через пайп |

## Лицензия

MIT
