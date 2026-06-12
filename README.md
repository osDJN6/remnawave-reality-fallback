# Remnawave REALITY Fallback

Скрипт для маскировки VPN-сервера под настоящий веб-сайт. Защита от активного зондирования ТСПУ и от прямого сканирования IP.

## Схема

```
Клиент → Xray (443, VLESS+REALITY)
    ├── VPN-клиент (знает ключ)        → туннель → интернет
    ├── зондировщик без ключа          → REALITY уводит на www.microsoft.com:443 (TLS-слой)
    └── валидный TLS, но не-VLESS HTTP  → fallback → nginx (8080) → донор

Сканирование порта 80 на IP          → nginx (80) → донор
```

**Кто что закрывает:**

- **REALITY (TLS-слой).** Зондировщик без приватного ключа не проходит аутентификацию и прозрачно уводится на реальный `www.microsoft.com:443` (поле `realitySettings.dest`). Видит настоящий TLS-сертификат и контент Microsoft. Это основная защита от активного зондирования — её делает сам Xray, без nginx.
- **nginx fallback (8080).** Подхватывает редкий случай: клиент завершил TLS к нашему серверу, но прислал не-VLESS HTTP. Отдаёт контент донора как обычный обратный прокси.
- **nginx на :80.** То, что реально видно при сканировании IP по HTTP. Проксирует на донора, чтобы порт 80 выглядел живым и «майкрософтовским».

## Что защищает

|Слой|Атака                           |Защита                                                                 |
|----|--------------------------------|-----------------------------------------------------------------------|
|TLS |Активное зондирование без ключа |REALITY уводит на реальный microsoft.com:443, валидный сертификат      |
|TLS |Поведенческий анализ хендшейка  |TLS fingerprint = настоящий Microsoft (REALITY «занимает» его хендшейк)|
|HTTP|Прямое сканирование IP (80/8080)|nginx отдаёт контент донора с его подлинными заголовками               |

## Требования

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- Порт 443 свободен (его займёт Xray; скрипт это проверит и предупредит)
- Remnawave Node (устанавливается отдельно)

## Установка

```bash
# Минимум — с привязкой Node API к IP панели (рекомендуется):
PANEL_IP=203.0.113.10 bash deploy.sh

# Свой донор / порты:
SNI_DONOR=learn.microsoft.com PANEL_IP=203.0.113.10 bash deploy.sh

# Осознанно открыть Node API всем (если IP панели заранее неизвестен):
ALLOW_NODE_API_PUBLIC=1 bash deploy.sh
```

### Переменные окружения

|Переменная             |По умолчанию       |Назначение                                            |
|-----------------------|-------------------|------------------------------------------------------|
|`SNI_DONOR`            |`www.microsoft.com`|Домен-донор для маскировки                            |
|`FALLBACK_PORT`        |`8080`             |Локальный порт nginx-fallback                         |
|`NODE_API_PORT`        |`3010`             |Порт Remnawave Node API                               |
|`PANEL_IP`             |—                  |IP панели; Node API откроется только ему              |
|`ALLOW_NODE_API_PUBLIC`|`0`                |`=1` — открыть Node API всем, если `PANEL_IP` не задан|


> Если не задан ни `PANEL_IP`, ни `ALLOW_NODE_API_PUBLIC=1`, скрипт остановится и не станет открывать management-порт ноды наружу.

## Настройка Remnawave

### 1. Config Profile

Создайте Config Profile в панели (замените ключи на свои):

```json
{
  "api": { "tag": "api", "services": ["HandlerService", "StatsService", "LoggerService"] },
  "log": { "loglevel": "warning" },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": {
      "statsInboundUplink": true, "statsOutboundUplink": true,
      "statsInboundDownlink": true, "statsOutboundDownlink": true
    }
  },
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
      { "ip": ["geoip:private"], "type": "field", "outboundTag": "blocked" }
    ]
  },
  "inbounds": [
    {
      "tag": "api", "port": 61000, "listen": "127.0.0.1",
      "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "VLESS-REALITY", "port": 443, "listen": "",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [{ "dest": 8080, "xver": 0 }]
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "dest": "www.microsoft.com:443",
          "show": false,
          "xver": 0,
          "shortIds": ["your-short-id"],
          "privateKey": "your-private-key",
          "serverNames": ["www.microsoft.com", "microsoft.com"]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ]
}
```

> `dest` в `realitySettings` (donor на :443) и `fallbacks[].dest` (nginx на 8080) — разные вещи. Первое использует сам REALITY при провале аутентификации; второе — для пост-хендшейк не-VLESS трафика. Совпадение донора в обоих местах желательно для консистентности.

### 2. Host

- **address:** IP сервера
- **port:** 443
- **security:** DEFAULT
- **fingerprint:** chrome
- **SNI:** [www.microsoft.com](http://www.microsoft.com)

### 3. Генерация ключей REALITY

```bash
docker exec remnanode /usr/local/bin/xray x25519   # privateKey + publicKey
openssl rand -hex 4                                  # shortId (8 hex)
```

- `Private key` → в `privateKey` конфига
- `Public key` → панель подставит в подписку
- `shortId` → в массив `shortIds`

> Ключи **не коммитьте** в репозиторий — для этого добавлен `.gitignore`.

## Проверки

```bash
# Fallback отдаёт контент донора:
curl http://127.0.0.1:8080/

# Зондировщик видит донора по 443:
curl -k --resolve www.microsoft.com:443:YOUR_SERVER_IP https://www.microsoft.com/

# Порт 80 выглядит живым:
curl -I http://YOUR_SERVER_IP/
```

## Выбор SNI-донора

**Хорошие доноры** (глобальный CDN, IP совпадает с реальными):

- `www.microsoft.com` — работает почти везде
- `learn.microsoft.com` — Microsoft Docs
- `github.com`

**Плохие доноры:**

- `icloud.com`, `apple.com` — Apple держит IP в собственных ASN, несоответствие видно сразу
- Любые сайты без CDN — IP сервера не совпадёт с реальным IP сайта

## Заметки по безопасности

- **SSH-баннер.** Скрипт убирает суффикс `-Debian`, но **версия OpenSSH всё равно видна** в протокольном баннере — полностью скрыть её без пересборки нельзя. Не рассчитывайте на это как на маскировку.
- **Node API.** По умолчанию открывается только для `PANEL_IP`. Открытие всем — только явным `ALLOW_NODE_API_PUBLIC=1`.
- **Firewall.** SSH-порт определяется автоматически из `sshd_config`, чтобы не потерять доступ при включении UFW.
- **DNS.** nginx-resolver берётся из системного `/etc/resolv.conf`, без жёсткой привязки к одному внешнему DNS.