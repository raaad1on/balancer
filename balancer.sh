#!/bin/bash

# =================================================================
# Xray Balancer Analyzer (Self-Healing Edition)
# Usage: curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash
# =================================================================

CONTAINER_NAME="remnanode"
LOG_FILE="/var/log/supervisor/xray.out.log"

echo -e "\e[34m[*] Инициализация проверки окружения...\e[0m"

# 1. Проверка зависимостей на хосте
if ! command -v jq &>/dev/null; then
    echo -e "\e[33m[!] На хосте не найден jq. Установка...\e[0m"
    sudo apt update && sudo apt install -y jq &>/dev/null
fi

# 2. Проверка и доустановка curl внутри контейнера
CHECK_CURL=$(sudo docker exec $CONTAINER_NAME command -v curl 2>/dev/null)
if [ -z "$CHECK_CURL" ]; then
    echo -e "\e[33m[!] Внутри контейнера не найден curl. Попытка установки...\e[0m"
    # Пытаемся определить пакетный менеджер (apt или apk)
    sudo docker exec $CONTAINER_NAME sh -c "
        if command -v apt-get >/dev/null; then
            apt-get update && apt-get install -y curl
        elif command -v apk >/dev/null; then
            apk add --no-cache curl
        else
            echo 'ERROR: No package manager found' && exit 1
        fi
    " &>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[!] Не удалось установить curl автоматически. Проверь интернет в контейнере.\e[0m"
        exit 1
    fi
    echo -e "\e[32m[+] Curl успешно установлен в контейнер.\e[0m"
fi

# 3. Поиск процесса и данных API
PROC_DATA=$(sudo docker exec $CONTAINER_NAME ps auxww | grep -E 'rw-core|xray' | grep -v grep | head -n 1)
GET_URL=$(echo "$PROC_DATA" | sed -n 's/.*token=\([^ ]*\).*/\1/p')
GET_SOCK=$(echo "$PROC_DATA" | sed -n 's/.* \(\/run\/[^? ]*\.sock\).*/\1/p')

if [[ -z "$GET_URL" || -z "$GET_SOCK" ]]; then
    echo -e "\e[31m[!] Ошибка: Не удалось вытащить параметры API из процесса.\e[0m"
    exit 1
fi

# 4. Получение конфига
CONFIG_JSON=$(sudo docker exec $CONTAINER_NAME curl -sS --fail --unix-socket "$GET_SOCK" "http://localhost/internal/get-config?token=$GET_URL")

if [[ -z "$CONFIG_JSON" ]]; then
    echo -e "\e[31m[!] Ошибка: API вернул пустой ответ.\e[0m"
    exit 1
fi

# 5. Парсинг и Логика
RAW_ERRORS=$(sudo docker exec $CONTAINER_NAME awk '/started/ {f=1; buf=""; next} f{buf=buf $0 ORS} END{printf "%s", buf}' $LOG_FILE | grep "error ping")
MAP=$(echo "$CONFIG_JSON" | jq -r '(.routing.balancers[]? | "\(.tag):\(.selector | join(","))"), (.. | objects | select(.tag != null and .selector != null) | "\(.tag):\(.selector | join(","))")' 2>/dev/null | sort -u)
ALL_OUTBOUNDS=$(echo "$CONFIG_JSON" | jq -r '.. | .outbounds? // empty | .[]?.tag' 2>/dev/null)

if [[ -z "$MAP" ]]; then
    echo -e "\e[33m[?] Балансировщики в конфиге не найдены.\e[0m"
    exit 0
fi

# 6. Визуализация
echo -e "\n\e[1;34m================= SRE DASHBOARD =================\e[0m"
echo -e "Timestamp: $(date '+%H:%M:%S') | Node: $(hostname)"
echo "-------------------------------------------------"
printf "%-25s | %-10s | %-10s\n" "BALANCER" "HEALTH" "NODES"
echo "-------------------------------------------------"

DETAILS=""
while IFS=: read -r b_name selector; do
    [[ -z "$b_name" || "$b_name" == "null" ]] && continue
    
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
