#!/bin/bash
set -euo pipefail

# ================================================================
# deploy-all.sh — Автоматический деплой REALITY Fallback на ноды
#
# Что делает:
#   1. Деплоит nginx fallback на каждую ноду (через SSH)
#   2. Генерирует x25519 ключи один раз (для всех нод)
#   3. Выводит готовый Config Profile JSON для панели Remnawave
#
# Использование:
#   1. Заполни секцию КОНФИГУРАЦИЯ ниже
#   2. bash deploy-all.sh
# ================================================================

# ================================================================
# КОНФИГУРАЦИЯ — заполни перед запуском
# ================================================================

# SNI-донор: сайт, под который маскируется сервер
SNI_DONOR="www.microsoft.com"

# Порт nginx fallback (Xray перенаправляет сюда зондировщиков)
FALLBACK_PORT="8080"

# Порт Remnawave Node API
NODE_API_PORT="3010"

# Ноды: "метка|IP|пользователь|пароль"
NODES=(
    "node1|95.85.226.153|root|jPaDOVw48d2y"
    # "node2|1.2.3.4|root|password"
    # "node3|5.6.7.8|root|password"
)

# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy.sh"

if [[ ! -f "$DEPLOY_SCRIPT" ]]; then
    log_error "deploy.sh не найден рядом со скриптом"
    exit 1
fi

if ! command -v sshpass &>/dev/null; then
    log_error "sshpass не установлен. Установи: brew install sshpass"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"

# ── Валидация конфига ─────────────────────────────────────────
if [[ ! "$SNI_DONOR" =~ ^[a-zA-Z0-9.\-]+$ ]]; then
    log_error "SNI_DONOR содержит недопустимые символы: '$SNI_DONOR'"
    exit 1
fi
if [[ ! "$FALLBACK_PORT" =~ ^[0-9]+$ ]] || (( FALLBACK_PORT < 1 || FALLBACK_PORT > 65535 )); then
    log_error "FALLBACK_PORT должен быть числом 1-65535"
    exit 1
fi
if [[ ! "$NODE_API_PORT" =~ ^[0-9]+$ ]] || (( NODE_API_PORT < 1 || NODE_API_PORT > 65535 )); then
    log_error "NODE_API_PORT должен быть числом 1-65535"
    exit 1
fi
if [[ ${#NODES[@]} -eq 0 ]]; then
    log_error "Список NODES пустой — заполни конфигурацию"
    exit 1
fi

# Результаты в строке (bash 3.2 совместимо — без declare -A)
SUMMARY_OK=""
SUMMARY_FAIL=""
FIRST_OK_NODE=""

# ================================================================
# Деплой на каждую ноду
# ================================================================
for node_config in "${NODES[@]}"; do
    IFS='|' read -r LABEL IP USER PASS <<< "$node_config"

    if [[ -z "$IP" || -z "$USER" ]]; then
        log_warn "Пропуск пустой записи в NODES"
        continue
    fi

    log_step "Нода: $LABEL ($IP)"

    # Копируем deploy.sh на ноду
    log_info "[$LABEL] Копирую deploy.sh..."
    if ! SSHPASS="$PASS" sshpass -e scp $SSH_OPTS "$DEPLOY_SCRIPT" "$USER@$IP:/tmp/remnawave-deploy.sh" 2>&1; then
        log_error "[$LABEL] Не удалось скопировать скрипт"
        SUMMARY_FAIL="${SUMMARY_FAIL}  ${RED}✗${NC}  $LABEL ($IP) — ошибка SCP\n"
        continue
    fi

    # Запускаем deploy.sh с параметрами через env
    log_info "[$LABEL] Запускаю деплой nginx..."
    if SSHPASS="$PASS" sshpass -e ssh $SSH_OPTS "$USER@$IP" \
        "SNI_DONOR='$SNI_DONOR' FALLBACK_PORT='$FALLBACK_PORT' NODE_API_PORT='$NODE_API_PORT' bash /tmp/remnawave-deploy.sh" 2>&1; then
        log_info "[$LABEL] Деплой успешен"
        SUMMARY_OK="${SUMMARY_OK}  ${GREEN}✓${NC}  $LABEL ($IP)\n"
        [[ -z "$FIRST_OK_NODE" ]] && FIRST_OK_NODE="$LABEL|$IP|$USER|$PASS"
    else
        log_error "[$LABEL] Деплой завершился с ошибкой"
        SUMMARY_FAIL="${SUMMARY_FAIL}  ${RED}✗${NC}  $LABEL ($IP) — ошибка деплоя\n"
    fi
done

# ================================================================
# Генерация x25519 ключей (один раз, для всех нод)
# ================================================================
log_step "Генерация x25519 ключей"

PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

if [[ -n "$FIRST_OK_NODE" ]]; then
    IFS='|' read -r F_LABEL F_IP F_USER F_PASS <<< "$FIRST_OK_NODE"

    # Пробуем через docker exec remnanode (если нода уже установлена)
    XRAY_OUT=$(SSHPASS="$F_PASS" sshpass -e ssh $SSH_OPTS "$F_USER@$F_IP" \
        "docker exec remnanode /usr/local/bin/xray x25519 2>/dev/null" 2>/dev/null || true)

    if echo "$XRAY_OUT" | grep -q "Private key:"; then
        PRIVATE_KEY=$(echo "$XRAY_OUT" | grep "Private key:" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$XRAY_OUT" | grep "Public key:" | awk '{print $NF}')
        log_info "Ключи получены через xray на $F_LABEL"
    else
        # Remnawave Node ещё не установлен — генерируем через openssl
        log_warn "remnanode не запущен — генерируем через openssl"
        KEYGEN_OUT=$(SSHPASS="$F_PASS" sshpass -e ssh $SSH_OPTS "$F_USER@$F_IP" 'bash -s' <<'KEYGEN' 2>/dev/null || true
PRIV_PEM=$(openssl genpkey -algorithm X25519 2>/dev/null)
PRIVATE=$(echo "$PRIV_PEM" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
PUBLIC=$(echo "$PRIV_PEM" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
echo "PRIVATE_KEY=$PRIVATE"
echo "PUBLIC_KEY=$PUBLIC"
KEYGEN
        )
        PRIVATE_KEY=$(echo "$KEYGEN_OUT" | grep "^PRIVATE_KEY=" | cut -d= -f2- | tr -d '[:space:]')
        PUBLIC_KEY=$(echo "$KEYGEN_OUT" | grep "^PUBLIC_KEY=" | cut -d= -f2- | tr -d '[:space:]')
        [[ -n "$PRIVATE_KEY" ]] && log_info "Ключи сгенерированы через openssl на $F_LABEL"
    fi

    SHORT_ID=$(SSHPASS="$F_PASS" sshpass -e ssh $SSH_OPTS "$F_USER@$F_IP" "openssl rand -hex 4" 2>/dev/null | tr -d '[:space:]' || true)
fi

# Fallback если всё не сработало
if [[ -z "$PRIVATE_KEY" ]]; then
    log_warn "Не удалось сгенерировать ключи автоматически"
    log_warn "После установки Remnawave Node выполни: docker exec remnanode /usr/local/bin/xray x25519"
    PRIVATE_KEY="ВСТАВЬ_PRIVATE_KEY"
    PUBLIC_KEY="ВСТАВЬ_PUBLIC_KEY"
fi
[[ -z "$SHORT_ID" ]] && SHORT_ID=$(openssl rand -hex 4 2>/dev/null || echo "aabbccdd")

# ================================================================
# Итоговый отчёт
# ================================================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ИТОГ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""
[[ -n "$SUMMARY_OK" ]]   && echo -e "$SUMMARY_OK"
[[ -n "$SUMMARY_FAIL" ]] && echo -e "$SUMMARY_FAIL"

echo ""
echo -e "${CYAN}════ Config Profile для панели Remnawave ════${NC}"
echo -e "${YELLOW}  Один профиль — для всех нод${NC}"
echo ""
echo -e "  privateKey: ${GREEN}$PRIVATE_KEY${NC}"
echo -e "  publicKey:  ${GREEN}$PUBLIC_KEY${NC}"
echo -e "  shortId:    ${GREEN}$SHORT_ID${NC}"
echo -e "  SNI:        ${GREEN}$SNI_DONOR${NC}"
echo ""
echo -e "  Вставь JSON ниже в панель: Xray config → Config Profiles → New"
echo ""

cat <<JSON_EOF
{
  "log": {
    "loglevel": "none"
  },
  "dns": {
    "servers": [
      "https+local://8.8.8.8",
      "https+local://1.1.1.1"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "VLESS-REALITY",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [
          { "dest": $FALLBACK_PORT, "xver": 0 }
        ]
      },
      "sniffing": {
        "enabled": false,
        "routeOnly": true,
        "destOverride": ["http", "tls", "quic", "fakedns"]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "${SNI_DONOR}:443",
          "serverNames": ["${SNI_DONOR}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "fingerprint": "chrome"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "BLOCK"
      },
      {
        "ip": ["geoip:private"],
        "type": "field",
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "domain": ["geosite:private"],
        "outboundTag": "BLOCK"
      }
    ]
  }
}
JSON_EOF

echo ""
echo -e "${CYAN}════ Host настройки для каждой ноды ════${NC}"
echo ""
echo -e "  address   = IP ноды"
echo -e "  port      = 443"
echo -e "  security  = tls"
echo -e "  sni       = ${GREEN}$SNI_DONOR${NC}"
echo -e "  fp        = chrome"
echo -e "  publicKey = ${GREEN}$PUBLIC_KEY${NC}"
echo -e "  shortId   = ${GREEN}$SHORT_ID${NC}"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
