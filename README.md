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

## Быстрый старт

**1. Установи зависимость (Mac):**
```bash
brew install sshpass
```

**2. Заполни ноды в `deploy-all.sh`:**
```bash
NODES=(
    "node1|1.2.3.4|root|password"
    "node2|5.6.7.8|root|password"
)
```

**3. Запусти:**
```bash
bash deploy-all.sh
```

**4. Скрипт автоматически:**
- Деплоит nginx fallback на каждую ноду
- Генерирует x25519 ключи (один раз — подходят для всех нод)
- Выводит готовый **Config Profile JSON** для вставки в панель Remnawave

**5. В панели Remnawave:**
- Вставь полученный JSON → Config Profiles → New
- Создай Host для каждой ноды (IP + publicKey + shortId из вывода скрипта)
- Привяжи все ноды к одному профилю

## Один Config Profile — все ноды

Один и тот же JSON применяется ко всем нодам. Панель Remnawave сама пушит конфиг на каждую ноду.

## Файлы

| Файл | Назначение |
|------|-----------|
| `deploy-all.sh` | Мастер-скрипт: деплой на все ноды + генерация ключей + вывод JSON |
| `deploy.sh` | Устанавливает nginx на одной ноде (вызывается автоматически) |

## Требования

- Ubuntu 22.04/24.04 или Debian 11/12 на нодах
- `sshpass` на локальной машине: `brew install sshpass`
- SSH root-доступ к нодам

## Рекомендуемые SNI-доноры

| Донор | Надёжность |
|-------|-----------|
| `www.microsoft.com` | ✅ Глобальный CDN, работает везде |
| `github.com` | ✅ Надёжно |
| Apple-домены | ❌ Собственный ASN — несоответствие IP детектируется |

## Генерация ключей вручную

Если нужно перегенерировать ключи:
```bash
# На ноде с установленным Remnawave Node:
docker exec remnanode /usr/local/bin/xray x25519

# shortId:
openssl rand -hex 4
```

## Проверка после деплоя

```bash
# Fallback отдаёт Microsoft:
curl http://127.0.0.1:8080/

# Зондировщик видит Microsoft:
curl -k --resolve www.microsoft.com:443:YOUR_NODE_IP https://www.microsoft.com/
```
