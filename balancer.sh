#!/bin/bash

# =================================================================
# Xray Balancer Analyzer (SRE Edition)
# =================================================================

CONTAINER_NAME="remnanode"
CONTAINER_PID=$(sudo docker inspect --format '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null)

# 1. Получение конфига через официальную cli команду
echo -e "\e[34m[*] Запрос конфигурации через cli --dump-config...\e[0m"
CONFIG_RAW=$(sudo docker exec $CONTAINER_NAME cli --dump-config 2>/dev/null | sed -n '/^{/,/^}/p')

if ! echo "$CONFIG_RAW" | jq . >/dev/null 2>&1; then
    echo -e "\e[31m[!] Ошибка: Не удалось получить конфиг через cli --dump-config\e[0m"
    exit 1
fi

# 2. Парсинг и Таблица
MAP=$(echo "$CONFIG_RAW" | jq -r '.. | objects | select(.tag != null and .selector != null) | "\(.tag):\(.selector | join(","))"' 2>/dev/null | sort -u)
ALL_OUTBOUNDS=$(echo "$CONFIG_RAW" | jq -r '.. | .outbounds? // empty | .[]?.tag' 2>/dev/null)
RAW_ERRORS=$(sudo docker exec $CONTAINER_NAME sh -c 'cat /var/log/xray/current 2>/dev/null || cat /var/log/supervisor/xray.out.log 2>/dev/null' 2>/dev/null | grep "error ping")

if [[ -z "$MAP" ]]; then
    echo -e "\e[33m[?] Балансировщики не найдены в конфиге.\e[0m"
    exit 0
fi

echo -e "\n\e[1;34m================= SRE DASHBOARD =================\e[0m"
printf "%-30s | %-10s | %-10s\n" "BALANCER" "HEALTH" "NODES"
echo "---------------------------------------------------------"

DETAILS=""
while IFS=: read -r b_name selector; do
    [[ -z "$b_name" ]] && continue
    search_pattern=$(echo "$selector" | sed 's/,/|^/g; s/^/^/')
    node_list=$(echo "$ALL_OUTBOUNDS" | grep -E "$search_pattern" | sort -u)

    b_total=0; b_alive=0; b_err_logs=""
    for tag in $node_list; do
        ((b_total++))
        safe_tag=$(echo "$tag" | sed 's/\./\\./g')
        err_line=$(echo "$RAW_ERRORS" | grep -E "with $safe_tag:" | tail -n 1)
        if [[ -n "$err_line" ]]; then
            b_err_logs="${b_err_logs}\n  \e[31m✖\e[0m $tag"
        else
            ((b_alive++))
        fi
    done

    printf "%-30s | %-10s | %d/%d\n" "$b_name" "$([[ $b_alive -eq $b_total ]] && echo -e "\e[32mCLEAN\e[0m" || echo -e "\e[33mFAIL\e[0m")" "$b_alive" "$b_total"
    [[ -n "$b_err_logs" ]] && DETAILS="${DETAILS}\n\e[1m[$b_name Faults]:\e[0m${b_err_logs}"
done <<< "$MAP"

[[ -n "$DETAILS" ]] && echo -e "\n\e[1;33m--- INCIDENTS ---\e[0m$DETAILS"

# =================================================================
# OUTBOUND METRICS (observatory from /debug/vars)
# =================================================================
echo -e "\n\e[1;34m=============== OUTBOUND METRICS ===============\e[0m"

DEBUG_VARS=$(sudo nsenter -t "$CONTAINER_PID" -n curl -sS http://127.0.0.1:11111/debug/vars 2>/dev/null)

if ! echo "$DEBUG_VARS" | jq -e '.observatory' >/dev/null 2>&1; then
    echo -e "\e[33m[?] Observatory метрики недоступны.\e[0m"
else
  # Собираем все entry из observatory во временный файл
  echo "$DEBUG_VARS" | jq -r '.observatory | to_entries[] | "\(.key)|\(.value.delay // "-")"' 2>/dev/null > /tmp/balancer_obs.tmp

  # Собираем пары prefix|balancer из MAP (сортируем от длинных префиксов к коротким)
  echo "$MAP" > /tmp/balancer_map_raw.tmp
  > /tmp/balancer_map.tmp
  while IFS=: read -r b_name selector; do
      [[ -z "$b_name" ]] && continue
      IFS=',' read -ra prefixes <<< "$selector"
      for prefix in "${prefixes[@]}"; do
          echo "$prefix|$b_name" >> /tmp/balancer_map.tmp
      done
  done < /tmp/balancer_map_raw.tmp
  sort -t'|' -k1,1 -r /tmp/balancer_map.tmp -o /tmp/balancer_map.tmp
  rm -f /tmp/balancer_map_raw.tmp

  # Собираем данные: balancer|loc|raw|xhttp
  > /tmp/balancer_data.tmp
  while IFS='|' read -r tag delay; do
      [[ -z "$tag" || -z "$delay" ]] && continue

      # Определяем балансировщик по префикс-матчингу
      matched="Unknown-Pool"
      while IFS='|' read -r prefix b_name; do
          if [[ "$tag" == "$prefix"* ]]; then
              matched="$b_name"
              break
          fi
      done < /tmp/balancer_map.tmp

      # Извлекаем локацию
      loc=$(echo "$tag" | sed 's/-raw$//; s/-xHTTP$//' | sed 's/\..*//; s/-.*//')

      # Определяем тип
      if [[ "$tag" == *-raw ]]; then
          echo "$matched|$loc|raw|$delay" >> /tmp/balancer_data.tmp
      elif [[ "$tag" == *-xHTTP ]]; then
          echo "$matched|$loc|xhttp|$delay" >> /tmp/balancer_data.tmp
      fi
  done < /tmp/balancer_obs.tmp

  # Группируем и выводим
  prev_balancer=""
  prev_loc=""
  raw_val=""
  xhttp_val=""
  while IFS='|' read -r b_name loc ptype delay; do
      if [[ "$b_name" != "$prev_balancer" ]]; then
          if [[ -n "$prev_loc" ]]; then
              printf "%-22s | %-10s | %-10s\n" "$prev_loc" "$raw_val" "$xhttp_val"
          fi
          [[ -n "$prev_balancer" ]] && echo ""
          echo -e "\n=== $b_name ==="
          printf "%-22s | %-10s | %-10s\n" "LOCATION" "RAW (ms)" "xHTTP (ms)"
          prev_balancer="$b_name"
          prev_loc=""
          raw_val=""
          xhttp_val=""
      fi
      if [[ "$loc" != "$prev_loc" ]]; then
          if [[ -n "$prev_loc" ]]; then
              printf "%-22s | %-10s | %-10s\n" "$prev_loc" "$raw_val" "$xhttp_val"
          fi
          prev_loc="$loc"
          raw_val="-"
          xhttp_val="-"
      fi
      if [[ "$ptype" == "raw" ]]; then
          raw_val="$delay"
      else
          xhttp_val="$delay"
      fi
  done < <(sort -t'|' -k1,1 -k2,2 -k3,3 /tmp/balancer_data.tmp)
  # Последняя строка
  if [[ -n "$prev_loc" ]]; then
      printf "%-22s | %-10s | %-10s\n" "$prev_loc" "$raw_val" "$xhttp_val"
  fi

  rm -f /tmp/balancer_obs.tmp /tmp/balancer_map.tmp /tmp/balancer_data.tmp
fi