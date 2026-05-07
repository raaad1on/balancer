#!/bin/bash

# =================================================================
# Xray Balancer Analyzer (SRE Debug Edition)
# Usage: curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash
# =================================================================

CONTAINER_NAME="remnanode"
LOG_FILE="/var/log/supervisor/xray.out.log"

# 1. Поиск процесса и данных API
PROC_DATA=$(sudo docker exec $CONTAINER_NAME ps auxww | grep -E 'rw-core|xray' | grep -v grep | head -n 1)

# Более надежный способ вытащить токен и сокет (без -P)
GET_URL=$(echo "$PROC_DATA" | sed -n 's/.*token=\([^ ]*\).*/\1/p')
GET_SOCK=$(echo "$PROC_DATA" | sed -n 's/.* \(\/run\/[^? ]*\.sock\).*/\1/p')

if [[ -z "$GET_URL" ]]; then
    echo -e "\e[31m[!] Ошибка: Токен API не найден. Проверь процесс в докере.\e[0m"
    exit 1
fi

# 2. Получение конфига
CONFIG_JSON=$(sudo docker exec $CONTAINER_NAME curl -sS --fail --unix-socket "$GET_SOCK" "http://localhost/internal/get-config?token=$GET_URL")

if [[ -z "$CONFIG_JSON" ]]; then
    echo -e "\e[31m[!] Ошибка: API вернул пустой ответ.\e[0m"
    exit 1
fi

# 3. Сбор логов и парсинг
RAW_ERRORS=$(sudo docker exec $CONTAINER_NAME awk '/started/ {f=1; buf=""; next} f{buf=buf $0 ORS} END{printf "%s", buf}' $LOG_FILE | grep "error ping")

# Пытаемся распарсить балансировщики двумя способами
MAP=$(echo "$CONFIG_JSON" | jq -r '(.routing.balancers[]? | "\(.tag):\(.selector | join(","))"), (.. | objects | select(.tag != null and .selector != null) | "\(.tag):\(.selector | join(","))")' 2>/dev/null | sort -u)
ALL_OUTBOUNDS=$(echo "$CONFIG_JSON" | jq -r '.. | .outbounds? // empty | .[]?.tag' 2>/dev/null)

# Если MAP все еще пустой - выводим дебаг
if [[ -z "$MAP" ]]; then
    echo -e "\e[33m[?] Балансировщики не найдены. Первые 100 символов ответа API:\e[0m"
    echo "$CONFIG_JSON" | cut -c1-100
    echo -e "\n\e[36mСовет: проверь, что в конфиге есть секция \"routing\": { \"balancers\": [...] }\e[0m"
    exit 0
fi

# 4. Визуализация
echo -e "\n\e[1;34m================= SRE DASHBOARD =================\e[0m"
echo -e "Timestamp: $(date '+%H:%M:%S') | Node: $(hostname)"
echo "-------------------------------------------------"
printf "%-25s | %-10s | %-10s\n" "BALANCER" "HEALTH" "NODES"
echo "-------------------------------------------------"

DETAILS=""
while IFS=: read -r b_name selector; do
    [[ -z "$b_name" || "$b_name" == "null" ]] && continue
    
    # Регулярка для префиксов
    search_pattern=$(echo "$selector" | sed 's/,/|^/g; s/^/^/')
    node_list=$(echo "$ALL_OUTBOUNDS" | grep -E "$search_pattern" | sort -u)
    
    b_total=0; b_alive=0; b_err_logs=""

    for tag in $node_list; do
        ((b_total++))
        # Экранируем точки в тегах (актуально для твоих новых логов типа al.anyway)
        safe_tag=$(echo "$tag" | sed 's/\./\\./g')
        err_line=$(echo "$RAW_ERRORS" | grep -E "with $safe_tag:" | tail -n 1)
        
        if [[ -n "$err_line" ]]; then
            case "$err_line" in
                *closed*pipe*) msg="CLOSED_PIPE" ;;
                *deadline*)    msg="TIMEOUT" ;;
                *)             msg="ERROR" ;;
            esac
            b_err_logs="${b_err_logs}\n  \e[31m✖\e[0m %-25s -> %s"
            b_err_logs=$(printf "$b_err_logs" "$tag" "$msg")
        else
            ((b_alive++))
        fi
    done

    health="${b_alive}/${b_total}"
    if [[ $b_alive -eq $b_total ]]; then
        printf "%-25s | \e[32m%-10s\e[0m | %-10s\n" "$b_name" "CLEAN" "$health"
    elif [[ $b_alive -eq 0 ]]; then
        printf "%-25s | \e[31m%-10s\e[0m | %-10s\n" "$b_name" "DEAD" "$health"
    else
        printf "%-25s | \e[33m%-10s\e[0m | %-10s\n" "$b_name" "UNSTABLE" "$health"
    fi
    [[ -n "$b_err_logs" ]] && DETAILS="${DETAILS}\n\e[1m[$b_name Faults]:\e[0m${b_err_logs}"
done <<< "$MAP"

[[ -n "$DETAILS" ]] && echo -e "\n\e[1;33m--- DETAILED INCIDENTS ---\e[0m$DETAILS"
echo -e "\n\e[1;34m=================================================\e[0m\n"
