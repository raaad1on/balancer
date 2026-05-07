# Xray Balancer Analyzer (SRE Edition)

Анализ состояния балансировщиков Xray на основе префиксов с визуализацией в реальном времени.

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

```
================= SRE DASHBOARD =================
Timestamp: 14:23:45 | Match Mode: PREFIX-ONLY
-------------------------------------------------
BALANCER             | HEALTH     | NODES
-------------------------------------------------
EU-Balancer          | CLEAN      | 4/4
US-Balancer          | UNSTABLE   | 3/4
ASIA-Balancer        | DEAD       | 0/2
[...]

--- DETAILED INCIDENTS ---
[EU-Balancer Faults]:
  ✖ eu-node-3        -> TIMEOUT
```

### Статусы здоровья

- **CLEAN** 🟢 — все ноды работают
- **UNSTABLE** 🟡 — часть нод упала
- **DEAD** 🔴 — все ноды недоступны
- **EMPTY** ⚪ — нет нод в селекторе

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

1. **Извлечение API kredentials** — из процесса `rw-core` в контейнере
2. **Загрузка конфига** — через Unix-сокет (без временных файлов)
3. **Анализ логов** — поиск ошибок ping после последнего рестарта
4. **Парсинг результатов** — jq для структурированного разбора JSON

## 🛡️ Особенности Production

- ✅ **Без временных файлов** — конфиг хранится только в переменных
- ✅ **Проверки безопасности** — Docker и контейнер должны существовать
- ✅ **One-liner ready** — корректная обработка потоков для `curl | bash`
- ✅ **Prefix-only mode** — 1de не «залетит» в EU-Balancer
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

## 🤝 Лицензия

MIT

## 📧 Feedback

Найдешь баг или хочешь фичу? Создай Issue или PR в репозитории.
