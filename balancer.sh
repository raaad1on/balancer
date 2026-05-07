#!/bin/bash

CONTAINER_NAME="remnanode"

echo -e "\e[34m[*] Определяю операционную систему контейнера...\e[0m"

# 1. Инспекция OS внутри контейнера
OS_TYPE=$(sudo docker exec $CONTAINER_NAME sh -c '
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo $ID
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "unknown"
    fi
' 2>/dev/null)

echo -e "\e[32m[+] Дистрибутив контейнера: $OS_TYPE\e[0m"

# 2. Попытка установки curl в зависимости от дистрибутива
if ! sudo docker exec $CONTAINER_NAME command -v curl &>/dev/null; then
    echo -e "\e[33m[!] Curl не найден. Пытаюсь установить для $OS_TYPE...\e[0m"
    
    case "$OS_TYPE" in
        "ubuntu"|"debian")
            sudo docker exec $CONTAINER_NAME apt-get update && \
            sudo docker exec $CONTAINER_NAME apt-get install -y curl &>/dev/null
            ;;
        "alpine")
            sudo docker exec $CONTAINER_NAME apk add --no-cache curl &>/dev/null
            ;;
        "centos"|"rhel"|"fedora")
            sudo docker exec $CONTAINER_NAME yum install -y curl &>/dev/null
            ;;
        *)
            echo -e "\e[31m[!] Неизвестный дистрибутив или пакетный менеджер отсутствует.\e[0m"
            # Попробуем wget как последний шанс, он часто вшит в busybox
            if ! sudo docker exec $CONTAINER_NAME command -v wget &>/dev/null; then
                 echo -e "\e[31m[!] Даже wget не найден. Контейнер слишком обрезан.\e[0m"
            fi
            ;;
    esac
fi

# 3. Проверка результата установки
if sudo docker exec $CONTAINER_NAME command -v curl &>/dev/null; then
    echo -e "\e[32m[+] Curl готов к работе.\e[0m"
else
    echo -e "\e[31m[!] Не удалось подготовить curl внутри контейнера.\e[0m"
    # Если это distroless, здесь можно добавить логику вытягивания конфига через cat /proc/... 
    # или выполнение бинарника самого xray с флагом api, если он это умеет.
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
