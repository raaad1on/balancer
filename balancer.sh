#!/bin/bash

# =================================================================
# Xray Balancer Analyzer (SRE Edition)
# Description: Анализ состояния балансировщиков на основе префиксов
# Usage: curl -sSL https://raw.githubusercontent.com/USER/REPO/main/balancer.sh | sudo bash
# =================================================================

# 1. Проверка окружения
for cmd in jq curl docker awk; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

# 2. Сбор данных из контейнера
CONTAINER_NAME="remnanode"
LOG_FILE="/var/log/supervisor/xray.out.log"

# Проверка, запущен ли контейнер
if ! sudo docker ps | grep -q $CONTAINER_NAME; then
    echo "Error: Container $CONTAINER_NAME is not running."
    exit 1
fi

# Извлечение токена и сокета
GET_URL=$(sudo docker exec $CONTAINER_NAME ps aux | grep rw-core | grep -v grep | awk -F'token=' '{print $2}' | awk '{print $1}')
GET_SOCK=$(sudo docker exec $CONTAINER_NAME ps aux | grep rw-core | grep -v grep | grep -oP '/run/[^? ]+\.sock')

if [[ -z "$GET_URL" || -z "$GET_SOCK" ]]; then
    echo "Error: Could not extract API credentials from process."
    exit 1
fi

# Получение конфига во временную переменную (без лишних файлов на диске)
CONFIG_JSON=$(sudo docker exec $CONTAINER_NAME curl -sS --fail --unix-socket "$GET_SOCK" "http://localhost/internal/get-config?token=$GET_URL")

if [[ -z "$CONFIG_JSON" ]]; then
    echo "Error: API request failed."
    exit 1
fi

# Чтение логов после последнего рестарта
RAW_ERRORS=$(sudo docker exec $CONTAINER_NAME awk '/started/ {f=1; buf=""; next} f{buf=buf $0 ORS} END{printf "%s", buf}' $LOG_FILE | grep "error ping")

# Парсинг балансировщиков и аутбаундов
MAP=$(echo "$CONFIG_JSON" | jq -r '.. | objects | select(.tag != null and .selector != null) | "\(.tag):\(.selector | join(","))"' 2>/dev/null)
ALL_OUTBOUNDS=$(echo "$CONFIG_JSON" | jq -r '.. | .outbounds? // empty | .[]?.tag' 2>/dev/null)

# 3. Визуализация
echo -e "\n\e[1;34m================= SRE DASHBOARD =================\e[0m"
echo -e "Timestamp: $(date '+%H:%M:%S') | Match Mode: PREFIX-ONLY"
echo "-------------------------------------------------"
printf "%-20s | %-10s | %-10s\n" "BALANCER" "HEALTH" "NODES"
echo "-------------------------------------------------"

DETAILS=""
total_issues=0

while IFS=: read -r b_name selector; do
    [[ -z "$b_name" ]] && continue
    
    # Prefix-matching logic
    search_pattern=$(echo "$selector" | sed 's/,/|^/g; s/^/^/')
    node_list=$(echo "$ALL_OUTBOUNDS" | grep -E "$search_pattern" | sort -u)
    
    b_total=0
    b_alive=0
    b_err_logs=""

    for tag in $node_list; do
        ((b_total++))
        err_line=$(echo "$RAW_ERRORS" | grep -F "with $tag:" | tail -n 1)
        
        if [[ -n "$err_line" ]]; then
            case "$err_line" in
                *closed*pipe*) msg="CLOSED_PIPE" ;;
                *deadline*)    msg="TIMEOUT" ;;
                *)             msg="ERROR" ;;
            esac
            b_err_logs="${b_err_logs}\n  \e[31m✖\e[0m %-15s -> %s"
            b_err_logs=$(printf "$b_err_logs" "$tag" "$msg")
        else
            ((b_alive++))
        fi
    done

    # Output formatting
    health="${b_alive}/${b_total}"
    if [[ $b_total -eq 0 ]]; then
        printf "%-20s | \e[37m%-10s\e[0m | %-10s\n" "$b_name" "EMPTY" "0/0"
    elif [[ $b_alive -eq $b_total ]]; then
        printf "%-20s | \e[32m%-10s\e[0m | %-10s\n" "$b_name" "CLEAN" "$health"
    elif [[ $b_alive -eq 0 ]]; then
        printf "%-20s | \e[31m%-10s\e[0m | %-10s\n" "$b_name" "DEAD" "$health"
        ((total_issues++))
    else
        printf "%-20s | \e[33m%-10s\e[0m | %-10s\n" "$b_name" "UNSTABLE" "$health"
        ((total_issues++))
    fi
    
    [[ -n "$b_err_logs" ]] && DETAILS="${DETAILS}\n\e[1m[$b_name Faults]:\e[0m${b_err_logs}"
done <<< "$MAP"

if [[ -n "$DETAILS" ]]; then
    echo -e "\n\e[1;33m--- DETAILED INCIDENTS ---\e[0m"
    echo -e "$DETAILS"
fi

echo -e "\n\e[1;34m=================================================\e[0m\n"