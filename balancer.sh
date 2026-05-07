#!/bin/bash

# =================================================================
# Xray Balancer Analyzer (Universal Edition)
# Usage: curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash
# =================================================================

CONTAINER_NAME="remnanode"
LOG_FILE="/var/log/supervisor/xray.out.log"

# 1. Поиск процесса и данных API
# Ищем и rw-core, и xray, берем полное дерево процессов (ww)
PROC_DATA=$(sudo docker exec $CONTAINER_NAME ps auxww | grep -E 'rw-core|xray' | grep -v grep | head -n 1)

GET_URL=$(echo "$PROC_DATA" | grep -oP 'token=\K[^ ]+')
GET_SOCK=$(echo "$PROC_DATA" | grep -oP '/run/[^? ]+\.sock')

if [[ -z "$GET_URL" ]]; then
    echo -e "\e[31m[!] Ошибка: Токен API не найден в процессе. Проверь 'ps aux' внутри контейнера.\e[0m"
    exit 1
fi

# 2. Получение конфига
CONFIG_JSON=$(sudo docker exec $CONTAINER_NAME curl -sS --fail --unix-socket "$GET_SOCK" "http://localhost/internal/get-config?token=$GET_URL")

if [[ -z "$CONFIG_JSON" || "$CONFIG_JSON" == "{}" ]]; then
    echo -e "\e[31m[!] Ошибка: API вернул пустой конфиг.\e[0m"
    exit 1
fi

# 3. Сбор логов и парсинг
RAW_ERRORS=$(sudo docker exec $CONTAINER_NAME awk '/started/ {f=1; buf=""; next} f{buf=buf $0 ORS} END{printf "%s", buf}' $LOG_FILE | grep "error ping")
MAP=$(echo "$CONFIG_JSON" | jq -r '.. | objects | select(.tag != null and .selector != null) | "\(.tag):\(.selector | join(","))"' 2>/dev/null)
ALL_OUTBOUNDS=$(echo "$CONFIG_JSON" | jq -r '.. | .outbounds? // empty | .[]?.tag' 2>/dev/null)

if [[ -z "$MAP" ]]; then
    echo -e "\n\e[33m[?] В конфиге не найдено активных балансировщиков (секция routing.balancers).\e[0m\n"
    exit 0
fi

# 4. Визуализация
echo -e "\n\e[1;34m================= SRE DASHBOARD =================\e[0m"
echo -e "Timestamp: $(date '+%H:%M:%S') | Node: $(hostname)"
echo "-------------------------------------------------"
printf "%-20s | %-10s | %-10s\n" "BALANCER" "HEALTH" "NODES"
echo "-------------------------------------------------"

DETAILS=""
while IFS=: read -r b_name selector; do
    [[ -z "$b_name" ]] && continue
    
    search_pattern=$(echo "$selector" | sed 's/,/|^/g; s/^/^/')
    node_list=$(echo "$ALL_OUTBOUNDS" | grep -E "$search_pattern" | sort -u)
    
    b_total=0; b_alive=0; b_err_logs=""

    for tag in $node_list; do
        ((b_total++))
        err_line=$(echo "$RAW_ERRORS" | grep -F "with $tag:" | tail -n 1)
        if [[ -n "$err_line" ]]; then
            case "$err_line" in
                *closed*pipe*) msg="CLOSED_PIPE" ;;
                *deadline*)    msg="TIMEOUT" ;;
                *)             msg="ERROR" ;;
            esac
            b_err_logs="${b_err_logs}\n  \e[31m✖\e[0m %-20s -> %s"
            b_err_logs=$(printf "$b_err_logs" "$tag" "$msg")
        else
            ((b_alive++))
        fi
    done

    health="${b_alive}/${b_total}"
    if [[ $b_alive -eq $b_total ]]; then
        printf "%-20s | \e[32m%-10s\e[0m | %-10s\n" "$b_name" "CLEAN" "$health"
    elif [[ $b_alive -eq 0 ]]; then
        printf "%-20s | \e[31m%-10s\e[0m | %-10s\n" "$b_name" "DEAD" "$health"
    else
        printf "%-20s | \e[33m%-10s\e[0m | %-10s\n" "$b_name" "UNSTABLE" "$health"
    fi
    [[ -n "$b_err_logs" ]] && DETAILS="${DETAILS}\n\e[1m[$b_name Faults]:\e[0m${b_err_logs}"
done <<< "$MAP"

[[ -n "$DETAILS" ]] && echo -e "\n\e[1;33m--- DETAILED INCIDENTS ---\e[0m$DETAILS"
echo -e "\n\e[1;34m=================================================\e[0m\n"
