#!/bin/bash

# =================================================================
# Xray Balancer Analyzer (Alpine & Root Fix)
# =================================================================

CONTAINER_NAME="remnanode"
LOG_FILE="/var/log/supervisor/xray.out.log"

echo -e "\e[34m[*] Определяю операционную систему контейнера...\e[0m"

# 1. Определение OS
OS_TYPE=$(sudo docker exec $CONTAINER_NAME sh -c '
    if [ -f /etc/os-release ]; then . /etc/os-release; echo $ID
    elif [ -f /etc/alpine-release ]; then echo "alpine"
    else echo "unknown"; fi' 2>/dev/null)

echo -e "\e[32m[+] Дистрибутив: $OS_TYPE\e[0m"

# 2. Установка Curl (с правами root)
if ! sudo docker exec $CONTAINER_NAME command -v curl &>/dev/null; then
    echo -e "\e[33m[!] Curl не найден. Установка...\e[0m"
    if [ "$OS_TYPE" == "alpine" ]; then
        sudo docker exec -u 0 $CONTAINER_NAME apk add --no-cache curl &>/dev/null
    else
        sudo docker exec -u 0 $CONTAINER_NAME apt-get update && \
        sudo docker exec -u 0 $CONTAINER_NAME apt-get install -y curl &>/dev/null
    fi
fi

# 3. УЛУЧШЕННЫЙ ПОИСК ПАРАМЕТРОВ
PROC_LINE=$(sudo docker exec $CONTAINER_NAME ps auxww | grep -E 'rw-core|xray' | grep -v grep | head -n 1)

# Извлекаем токен и сокет, удаляя возможные лишние символы и кавычки
GET_URL=$(echo "$PROC_LINE" | grep -oE 'token=[^ ]+' | cut -d= -f2 | tr -d '"'\'' ')
GET_SOCK=$(echo "$PROC_LINE" | grep -oE '/run/[^ ]+\.sock' | tr -d '"'\'' ')

if [[ -z "$GET_URL" || -z "$GET_SOCK" ]]; then
    echo -e "\e[31m[!] Ошибка: Не удалось найти токен или сокет в процессе.\e[0m"
    echo -e "\e[33mСтрока процесса:\e[0m $PROC_LINE"
    exit 1
fi

# 4. Запрос конфигурации
echo -e "\e[34m[*] Запрос API (Socket: $GET_SOCK)...\e[0m"
CONFIG_RAW=$(sudo docker exec $CONTAINER_NAME curl -sS --unix-socket "$GET_SOCK" "http://localhost/internal/get-config?token=$GET_URL" 2>&1)

if ! echo "$CONFIG_RAW" | jq . >/dev/null 2>&1; then
    echo -e "\e[31m[!] Ошибка API:\e[0m $CONFIG_RAW"
    exit 1
fi

# 5. Парсинг и Таблица (v11+)
MAP=$(echo "$CONFIG_RAW" | jq -r '.. | objects | select(.tag != null and .selector != null) | "\(.tag):\(.selector | join(","))"' 2>/dev/null | sort -u)
ALL_OUTBOUNDS=$(echo "$CONFIG_RAW" | jq -r '.. | .outbounds? // empty | .[]?.tag' 2>/dev/null)
RAW_ERRORS=$(sudo docker exec $CONTAINER_NAME awk '/started/ {f=1; buf=""; next} f{buf=buf $0 ORS} END{printf "%s", buf}' $LOG_FILE | grep "error ping")

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
