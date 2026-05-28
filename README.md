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

## Быстрый старт

### 1. Скачай скрипты

```bash
git clone https://github.com/osDJN6/remnawave-reality-fallback.git
cd remnawave-reality-fallback
```

### 2. Создай config.yaml

```bash
cp config.yaml.example config.yaml
```

Открой `config.yaml` и заполни:

```yaml
sni_donor: "www.microsoft.com"   # сайт для маскировки (не менять без причины)
fallback_port: 8080               # порт nginx fallback — только localhost, снаружи закрыт
node_api_port: 3000               # порт Remnawave Node API на ноде
panel_ip: "1.2.3.4"              # IP твоей панели Remnawave (порт API будет открыт только отсюда)

nodes:
  - label: "node1"
    ip: "1.2.3.4"      # IP ноды
    user: "root"        # SSH пользователь
    password: "..."     # SSH пароль

  - label: "node2"
    ip: "5.6.7.8"
    user: "root"
    password: "..."
```

> `config.yaml` находится в `.gitignore` — пароли не попадут в репозиторий.

### 3. Запусти деплой

**Python (Windows / Mac / Linux):**
```bash
pip install paramiko pyyaml
python deploy-all.py
```

**Bash (Mac / Linux):**
```bash
brew install sshpass   # Mac
# apt-get install sshpass  # Linux
bash deploy-all.sh
```

### 4. Скопируй вывод в панель

Скрипт выведет:
- **Config Profile JSON** — вставить в Remnawave: Xray Config → Config Profiles → New
- **publicKey, shortId** — для настройки хостов

---

## Настройка в панели Remnawave

### Config Profile

Перейди в **Xray Config → Config Profiles → New**, вставь JSON из вывода скрипта.

### Hosts

Для каждой ноды перейди в **Hosts → New** и заполни:

| Поле | Значение |
|------|----------|
| `address` | IP ноды |
| `port` | `443` |
| `security` | `tls` |
| `sni` | `www.microsoft.com` |
| `fp` | `firefox` |
| `publicKey` | из вывода скрипта |
| `shortId` | из вывода скрипта |

Привяжи все ноды к одному Config Profile.

---

## Что делает скрипт на каждой ноде

1. Устанавливает **nginx** с модулем `headers-more`
2. Настраивает nginx как обратный прокси на `www.microsoft.com`:
   - порт `8080` — только `127.0.0.1` (недоступен снаружи, только через Xray)
   - порт `80` — публичный, отдаёт страницу Microsoft
3. Настраивает **UFW**:
   - открывает порты `22`, `80`, `443`
   - порт Node API (`2222`) — только с IP панели
4. Скрывает **версию ОС** из SSH баннера (`DebianBanner no`)
5. Генерирует **x25519 ключи** (один раз, для всех нод)

---

## Файлы

| Файл | Назначение |
|------|-----------|
| `config.yaml` | Твои настройки — заполняешь перед запуском (в .gitignore) |
| `config.yaml.example` | Шаблон конфига |
| `deploy-all.py` | Мастер-скрипт Python (Windows / Mac / Linux) |
| `deploy-all.sh` | Мастер-скрипт Bash (Mac / Linux) |
| `deploy.sh` | Устанавливается на ноду — вызывается автоматически |

---

## Требования к нодам

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- SSH root-доступ
- Порт `443` свободен (не занят другим процессом)

---

## Рекомендуемые SNI-доноры

| Донор | Надёжность |
|-------|-----------|
| `www.microsoft.com` | ✅ Глобальный CDN, работает везде |
| `github.com` | ✅ Надёжно |
| Apple-домены | ❌ Собственный ASN — IP-несоответствие видно сразу |

---

## Проверка после деплоя

```bash
# На ноде — fallback отдаёт Microsoft:
curl http://127.0.0.1:8080/

# Снаружи — имитируем зондировщика (с любой машины):
curl -sk --resolve www.microsoft.com:443:YOUR_NODE_IP https://www.microsoft.com/ | head -5

# Проверка сертификата:
echo | openssl s_client -connect YOUR_NODE_IP:443 -servername www.microsoft.com 2>/dev/null | openssl x509 -noout -subject -issuer
```

Ожидаемый результат:
- `Server: AkamaiGHost` или `AkamaiNetStorage` — заголовок настоящего Microsoft CDN
- Сертификат выдан на `CN = www.microsoft.com` от Microsoft Corporation

---

## Генерация ключей вручную

Если скрипт не смог сгенерировать ключи автоматически:

```bash
# На ноде с запущенным Remnawave Node:
docker exec remnanode /usr/local/bin/xray x25519

# shortId:
openssl rand -hex 4
```
