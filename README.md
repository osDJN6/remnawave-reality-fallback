# Remnawave REALITY Fallback — автодеплой на несколько нод

Автоматическая установка nginx-маскировки (REALITY Fallback) на несколько нод Remnawave одной командой.

## Как работает

```
Входящий трафик → Xray (443, VLESS+REALITY)
    ├── VPN клиент с правильным ключом → туннель → интернет
    └── ТСПУ / зондировщик → nginx (8080) → www.microsoft.com
```

REALITY «одалживает» TLS-сертификат Microsoft — цензор видит настоящий сайт.

| Слой | Что видит цензор |
|------|-----------------|
| L3 (активное зондирование) | Настоящая страница Microsoft (200 OK) |
| L4 (TLS-анализ) | Валидный сертификат + TLS fingerprint Microsoft |

**→ [Подробное объяснение как это работает](HOW-IT-WORKS.md)**

---

## Вариант 1 — Python (Windows / Mac / Linux)

### Установка

```bash
pip install paramiko
```

### Настройка

Открой `deploy-all.py` и заполни секцию конфигурации:

```python
SNI_DONOR     = "www.microsoft.com"   # сайт для маскировки
FALLBACK_PORT = 8080                  # порт nginx fallback
NODE_API_PORT = 3010                  # порт Remnawave Node API

NODES = [
    {"label": "node1", "ip": "1.2.3.4", "user": "root", "password": "password"},
    {"label": "node2", "ip": "5.6.7.8", "user": "root", "password": "password"},
]
```

### Запуск

```bash
python deploy-all.py
```

На Windows:
```
python deploy-all.py
```

---

## Вариант 2 — Bash (Mac / Linux)

### Установка

```bash
brew install sshpass        # Mac
apt-get install sshpass     # Linux
```

### Настройка

Открой `deploy-all.sh` и заполни секцию конфигурации:

```bash
SNI_DONOR="www.microsoft.com"
FALLBACK_PORT="8080"
NODE_API_PORT="3010"

NODES=(
    "node1|1.2.3.4|root|password"
    "node2|5.6.7.8|root|password"
)
```

### Запуск

```bash
bash deploy-all.sh
```

---

## Что происходит после запуска

Оба скрипта выполняют одинаковые шаги:

1. **Деплоит nginx** на каждую ноду через SSH
2. **Генерирует x25519 ключи** — один раз, подходят для всех нод
3. **Выводит готовый Config Profile JSON** и Host настройки

---

## В панели Remnawave

1. **Config Profiles → New** — вставь полученный JSON
2. **Hosts → New** — для каждой ноды:
   - `address` = IP ноды
   - `port` = 443
   - `security` = tls
   - `sni` = www.microsoft.com
   - `fp` = chrome
   - `publicKey` и `shortId` из вывода скрипта
3. Привяжи все ноды к одному профилю

---

## Файлы

| Файл | Назначение |
|------|-----------|
| `deploy-all.py` | Мастер-скрипт для Windows / Mac / Linux (Python) |
| `deploy-all.sh` | Мастер-скрипт для Mac / Linux (Bash) |
| `deploy.sh` | Устанавливает nginx на ноде — вызывается автоматически |

---

## Требования к нодам

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- SSH root-доступ
- Порт 443 свободен

---

## Рекомендуемые SNI-доноры

| Донор | Надёжность |
|-------|-----------|
| `www.microsoft.com` | ✅ Глобальный CDN, работает везде |
| `github.com` | ✅ Надёжно |
| Apple-домены | ❌ Собственный ASN — IP несоответствие видно сразу |

---

## Генерация ключей вручную

```bash
# Приватный и публичный ключ (на ноде с Remnawave Node):
docker exec remnanode /usr/local/bin/xray x25519

# shortId:
openssl rand -hex 4
```

---

## Проверка после деплоя

```bash
# Fallback отдаёт Microsoft:
curl http://127.0.0.1:8080/

# Зондировщик видит Microsoft:
curl -k --resolve www.microsoft.com:443:YOUR_NODE_IP https://www.microsoft.com/
```
