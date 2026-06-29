# Xray Balancer Analyzer (SRE Edition)

Анализ состояния балансировщиков Xray с метриками задержек по аутбандам.

## 🚀 Быстрый старт

### Вариант 1: Одна команда (рекомендуется для Production)

```bash
curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash
```

### Вариант 2: Локальное выполнение

```bash
git clone https://github.com/raaad1on/balancer.git
cd balancer
chmod +x balancer.sh
sudo ./balancer.sh
```

### Вариант 3: Alias для частого использования

Добавить в `~/.bashrc`:

```bash
alias bcheck='curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash'
```

Затем просто запускать:

```bash
bcheck
```

## 📋 Требования

- **Docker** — для доступа к контейнеру `remnanode`
- **jq** — для парсинга JSON
- **curl** — для HTTP-запросов
- **awk** — для обработки логов
- **sudo доступ** — для работы с Docker и логами

Скрипт автоматически проверит наличие всех инструментов при запуске.

## 📊 Что показывает

### SRE Dashboard — статусы балансировщиков

```
================= SRE DASHBOARD =================
BALANCER                       | HEALTH     | NODES
---------------------------------------------------------
EU-Balancer                    | CLEAN      | 2/2
FI-balancer                    | CLEAN      | 6/6
YT-Balancer                    | FAIL       | 1/2

--- INCIDENTS ---
[YT-Balancer Faults]:
  ✖ al.anyway-raw
```

### Outbound Metrics — задержки по аутбандам

```
=============== OUTBOUND METRICS ===============
=== EU-Balancer ===
LOCATION  RAW (ms)  xHTTP (ms)
de        128       43
se01      86        24
=== FI-Balancer ===
LOCATION  RAW (ms)  xHTTP (ms)
fi04      82        27
fi05      65        27
=== YT-Balancer ===
LOCATION  RAW (ms)  xHTTP (ms)
al        161       51
```

### Статусы здоровья

- **CLEAN** 🟢 — все ноды работают
- **FAIL** 🟡 — часть нод упала
- **DEAD** 🔴 — все ноды недоступны

## 🔍 Как работает

### Логика prefix-matching

Скрипт использует **строгое совпадение по префиксу** для выбора нод:

```
Selector: "EU-,US-"
Ищет ноды начинающиеся с: ^EU- или ^US-

✓ EU-node-1       (соответствует ^EU-)
✓ US-east-01      (соответствует ^US-)
✗ EU-US-hybrid    (не берется! требуется ровно EU- или ровно US-)
✗ 1de              (не берется! не начинается с префикса)
```

### Сбор данных

1. **Извлечение API credentials** — из процесса `rw-core` в контейнере
2. **Загрузка конфига** — через Unix-сокет (без временных файлов)
3. **Анализ логов** — поиск ошибок ping после последнего рестарта
4. **Outbound метрики** — запрос к `/debug/vars` (порт 11111) внутри контейнера
5. **Парсинг результатов** — jq для структурированного разбора JSON

### Определение балансировщика по тегу

Для группировки outbound метрик используется функция определения балансировщика по префиксу outbound_tag:

| Префикс тега     | Балансировщик    |
|------------------|------------------|
| `al*`            | YT-Balancer      |
| `fi*`, `1se*`, `ch*` | FI-Balancer |
| `ru*`            | RU-Balancer      |
| `1de35*`         | DE-Balancer      |
| `de*`, `nl*`, `se*` | EU-Balancer   |
| `au*`            | AU-Balancer      |

## 🛡️ Особенности Production

- ✅ **Без временных файлов** — конфиг хранится только в переменных
- ✅ **Проверки безопасности** — Docker и контейнер должны существовать
- ✅ **One-liner ready** — корректная обработка потоков для `curl | bash`
- ✅ **Prefix-only mode** — 1de не «залетит» в EU-Balancer
- ✅ **Outbound метрики** — задержки RAW и xHTTP протоколов по каждому аутбанду
- ✅ **Структурированный вывод** — легко парсить в мониторинговые системы

## 📝 Примеры использования

### Проверка каждые 5 минут

```bash
*/5 * * * * curl -sSL https://raw.githubusercontent.com/raaad1on/balancer/main/balancer.sh | sudo bash >> /var/log/balancer-check.log 2>&1
```

### С логированием в файл

```bash
sudo bash balancer.sh | tee -a /var/log/balancer-status.log
```

### С отправкой в мониторинг (Prometheus/Grafana)

Номер можно парсить и отправлять метрики:

```bash
HEALTH=$(curl -sSL ... | grep "UNSTABLE\|DEAD" | wc -l)
```

## 🐛 Troubleshooting

| Ошибка | Решение |
|--------|---------|
| `Error: docker is not installed` | `apt install docker.io -y` |
| `Error: Container remnanode is not running` | Проверить: `docker ps` |
| `Error: Could not extract API credentials` | Проверить процесс: `docker exec remnanode ps aux \| grep rw-core` |
| `Error: API request failed` | Проверить логи контейнера: `docker logs remnanode` |
| `Observatory метрики недоступны` | Проверить что `/debug/vars` отвечает на порту 11111 внутри контейнера |

## 🤝 Лицензия

MIT

## 📧 Feedback

Найдешь баг или хочешь фичу? Создай Issue или PR в репозитории.