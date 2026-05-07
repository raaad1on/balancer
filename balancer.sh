#!/bin/bash

# =================================================================
# Xray Balancer Analyzer (Force Parsing Edition)
# Usage: curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash
# =================================================================

CONTAINER_NAME="remnanode"
LOG_FILE="/var/log/supervisor/xray.out.log"

echo -e "\e[34m[*] Инициализация проверки окружения...\e[0m"

# 1. Зависимости (хост)
if ! command -v jq &>/dev/null; then
    sudo apt update && sudo apt install -y jq &>/dev/null
fi

# 2. Зависимости (контейнер)
CHECK_CURL=$(sudo docker exec $CONTAINER_NAME command -v curl 2>/dev/null)
if [ -z "$CHECK_CURL" ]; then
    sudo docker exec $CONTAINER_NAME sh -c "if command -v apt-get >/dev/null; then apt-get update && apt-get install -y curl; elif command -v apk >/dev/null; then apk add --no-cache curl; fi" &>/dev/null
fi

# 3. Поиск параметров API
PROC_LINE=$(sudo docker exec $CONTAINER_NAME ps auxww | grep -E 'rw-core|xray' | grep -v grep | head -n 1)
GET_URL=$(echo "$PROC_LINE" | grep -oE 'token=[^ ]+' | cut -d= -f2 | sed 's/[[:space:]]*$//')
GET_SOCK=$(echo "$PROC_LINE" | grep -oE '/run/[^ ]+\.sock' | sed 's/[[:space:]]*$//')

if [[ -z "$GET_URL" || -z "$GET_SOCK" ]]; then
    echo -e "\e[31m[!] Ошибка: Параметры API не найдены.\e[0m"
    exit 1
fi

# 4. Получение конфига с защитой от ошибок вывода
echo -e "\e[34m[*] Запрос конфигурации из API...\e[0m"
CONFIG_RAW=$(sudo docker exec $CONTAINER_NAME curl -sS --unix-socket "$GET_SOCK" "http://localhost/internal/get-config?token=$GET_URL" 2>&1)

# Проверка: является ли ответ валидным JSON
if ! echo "$CONFIG_RAW" | jq . >/dev/null 2>&1; then
    echo -e "\e[31m[!] Ошибка: API вернул не JSON. Вероятно, curl вывел ошибку.\e[0m"
    echo -e "\e[33m--- RAW OUTPUT (Текст ошибки) ---\e[0m"
    echo "$CONFIG_RAW" | head -n 5
    echo -e "\e[33m---------------------------------\e[0m"
    
    # Мини-диагностика
    if [[ "$CONFIG_RAW" == *"Permission denied"* ]]; then
        echo -e "\e[36mСовет: Попробуй выдать права на сокет: sudo docker exec $CONTAINER_NAME chmod 666 $GET_SOCK\e[0m"
    elif [[ "$CONFIG_RAW" == *"401"* ]] || [[ "$CONFIG_RAW" == *"Unauthorized"* ]]; then
        echo -e "\e[36mСовет: Токен не подошел. Проверь пробелы в переменной GET_URL.\e[0m"
    fi
    exit 1
fi

CONFIG_JSON="$CONFIG_RAW"

# 5. Сбор логов
RAW_ERRORS=$(sudo docker exec $CONTAINER_NAME awk '/started/ {f=1; buf=""; next} f{buf=buf $0 ORS} END{printf "%s", buf}' $LOG_FILE | grep "error ping")

# 6. ГЛУБОКИЙ ПАРСИНГ (v11)
# Ищем балансировщики везде, где есть tag и selector
MAP=$(echo "$CONFIG_JSON" | jq -r '.. | objects | select(.tag != null and .selector != null) | "\(.tag):\(.selector | join(","))"' 2>/dev/null | sort -u)
ALL_OUTBOUNDS=$(echo "$CONFIG_JSON" | jq -r '.. | .outbounds? // empty | .[]?.tag' 2>/dev/null)

# Fallback: если MAP пуст, пробуем парсить напрямую из секции routing
if [[ -z "$MAP" ]]; then
    MAP=$(echo "$CONFIG_JSON" | jq -r '.routing.balancers[]? | "\(.tag):\(.selector | join(","))"' 2>/dev/null | sort -u)
fi

if [[ -z "$MAP" || "$MAP" == "null" ]]; then
    echo -e "\e[33m[?] Балансировщики не найдены в JSON. Проверь структуру конфига.\e[0m"
    echo -e "\e[36m--- DEBUG: Содержимое JSON (первые 200 символов) ---\e[0m"
    echo "$CONFIG_JSON" | jq -c '.' | cut -c1-200
    exit 0
fi

# 7. Визуализация
echo -e "\n\e[1;34m================= SRE DASHBOARD =================\e[0m"
echo -e "Timestamp: $(date '+%H:%M:%S') | Node: $(hostname)"
echo "---------------------------------------------------------"
printf "%-30s | %-10s | %-10s\n" "BALANCER" "HEALTH" "NODES"
echo "---------------------------------------------------------"

DETAILS=""
while IFS=: read -r b_name selector; do
    [[ -z "$b_name" || "$b_name" == "null" ]] && continue
    
    # Регулярка для префиксов
    search_pattern=$(echo "$selector" | sed 's/,/|^/g; s/^/^/')
    node_list=$(echo "$ALL_OUTBOUNDS" | grep -E "$search_pattern" | sort -u)
    
    b_total=0; b_alive=0; b_err_logs=""

    for tag in $node_list; do
        ((b_total++))
        safe_tag=$(echo "$tag" | sed 's/\./\\./g')
        err_line=$(echo "$RAW_ERRORS" | grep -E "with $safe_tag:" | tail -n 1)
        
        if [[ -n "$err_line" ]]; then
            case "$err_line" in
                *closed*pipe*) msg="CLOSED_PIPE" ;;
                *deadline*)    msg="TIMEOUT" ;;
                *)             msg="ERROR" ;;
            esac
            b_err_logs="${b_err_logs}\n  \e[31m✖\e[0m %-30s -> %s"
            b_err_logs=$(printf "$b_err_logs" "$tag" "$msg")
        else
            ((b_alive++))
        fi
    done

    health="${b_alive}/${b_total}"
    if [[ $b_alive -eq $b_total ]]; then
        printf "%-30s | \e[32m%-10s\e[0m | %-10s\n" "$b_name" "CLEAN" "$health"
    elif [[ $b_alive -eq 0 ]]; then
        printf "%-30s | \e[31m%-10s\e[0m | %-10s\n" "$b_name" "DEAD" "$health"
    else
        printf "%-30s | \e[33m%-10s\e[0m | %-10s\n" "$b_name" "UNSTABLE" "$health"
    fi
    [[ -n "$b_err_logs" ]] && DETAILS="${DETAILS}\n\e[1m[$b_name Faults]:\e[0m${b_err_logs}"
done <<< "$MAP"

[[ -n "$DETAILS" ]] && echo -e "\n\e[1;33m--- DETAILED INCIDENTS ---\e[0m$DETAILS"
echo -e "\n\e[1;34m=========================================================\e[0m\n"
