# Remnawave REALITY Fallback

Скрипт для маскировки VPN-сервера под настоящий веб-сайт. Защита от активного зондирования ТСПУ (слои 3 и 4).

## Схема

```
Клиент → Xray (443, VLESS+REALITY)
    ├── VPN клиент (знает ключ) → туннель → интернет
    └── зондировщик/ТСПУ → fallback → nginx (8080) → microsoft.com
```

**Как это работает:**
- Xray слушает на порту 443 с протоколом VLESS+REALITY
- Если подключается VPN-клиент с правильным ключом — устанавливается туннель
- Если подключается кто-то другой (ТСПУ, сканер, браузер) — видит настоящий сайт Microsoft
- REALITY "одалживает" настоящий TLS-сертификат Microsoft — неотличимо от реального сайта

## Что защищает

| Слой | Атака | Защита |
|------|-------|--------|
| 3 | Активное зондирование — ТСПУ отправляет тестовый запрос | Зондировщик получает настоящую страницу Microsoft |
| 4 | Поведенческий анализ — паттерны трафика | TLS fingerprint = настоящий Microsoft, сертификат валидный |

## Требования

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- Порт 443 свободен
- Remnawave Node (устанавливается отдельно)

## Установка

```bash
bash deploy.sh
```

Скрипт установит nginx как fallback-сервер и настроит firewall.

## Настройка Remnawave

### 1. Config Profile

Создайте Config Profile в панели с этим конфигом (замените ключи на свои):

```json
{
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService", "LoggerService"]
  },
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
      "tag": "api",
      "port": 61000,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "VLESS-REALITY",
      "port": 443,
      "listen": "",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [{ "dest": 8080, "xver": 0 }]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
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

### 2. Host

- **address:** IP сервера
- **port:** 443
- **security:** DEFAULT
- **fingerprint:** chrome
- **SNI:** www.microsoft.com

### 3. Генерация ключей REALITY

```bash
# Генерация privateKey и publicKey:
docker exec remnanode /usr/local/bin/xray x25519

# Генерация shortId (8 символов hex):
openssl rand -hex 4
```

- `Private key` → в `privateKey` конфига
- `Public key` → панель Remnawave подставит автоматически в подписку
- `shortId` → в массив `shortIds`

## Проверки

```bash
# Fallback работает — отдаёт Microsoft:
curl http://127.0.0.1:8080/

# Зондировщик видит Microsoft:
curl -k --resolve www.microsoft.com:443:YOUR_SERVER_IP https://www.microsoft.com/
```

## Выбор SNI-донора

Хорошие доноры:
- `www.microsoft.com` — глобальный CDN, работает везде
- `learn.microsoft.com` — Microsoft Docs
- `github.com` — GitHub

Плохие доноры (не использовать):
- `icloud.com`, `apple.com` — Apple держит IP в собственных ASN, несоответствие видно сразу
- Любые сайты без CDN — IP сервера не совпадёт с реальным IP сайта
