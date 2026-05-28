#!/bin/bash
set -euo pipefail

# ================================================================
# deploy-all.sh — Автоматический деплой REALITY Fallback на ноды
#
# Что делает:
#   1. Деплоит nginx fallback на каждую ноду (через SSH)
#   2. Генерирует x25519 ключи (один раз — для всех нод)
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

SSH_OPTS="-o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o ConnectTimeout=15 -o BatchMode=no"

declare -A RESULTS
FIRST_OK_NODE=""

# ================================================================
# Деплой на каждую ноду
# ================================================================
for node_config in "${NODES[@]}"; do
    IFS='|' read -r LABEL IP USER PASS <<< "$node_config"

    log_step "Нода: $LABEL ($IP)"

    # Копируем deploy.sh на ноду
    log_info "[$LABEL] Копирую deploy.sh..."
    if ! sshpass -p "$PASS" scp $SSH_OPTS "$DEPLOY_SCRIPT" "$USER@$IP:/tmp/remnawave-deploy.sh" 2>&1; then
        log_error "[$LABEL] Не удалось скопировать скрипт"
        RESULTS[$LABEL]="FAILED (scp)"
        continue
    fi

    # Запускаем deploy.sh с параметрами через env
    log_info "[$LABEL] Запускаю деплой nginx..."
    if sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$IP" \
        "SNI_DONOR='$SNI_DONOR' FALLBACK_PORT='$FALLBACK_PORT' NODE_API_PORT='$NODE_API_PORT' bash /tmp/remnawave-deploy.sh" 2>&1; then
        log_info "[$LABEL] Деплой успешен"
        RESULTS[$LABEL]="OK"
        [[ -z "$FIRST_OK_NODE" ]] && FIRST_OK_NODE="$LABEL|$IP|$USER|$PASS"
    else
        log_error "[$LABEL] Деплой завершился с ошибкой"
        RESULTS[$LABEL]="FAILED (deploy)"
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
    XRAY_OUT=$(sshpass -p "$F_PASS" ssh $SSH_OPTS "$F_USER@$F_IP" \
        "docker exec remnanode /usr/local/bin/xray x25519 2>/dev/null" 2>/dev/null || echo "")

    if echo "$XRAY_OUT" | grep -q "Private key:"; then
        PRIVATE_KEY=$(echo "$XRAY_OUT" | grep "Private key:" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$XRAY_OUT" | grep "Public key:" | awk '{print $NF}')
        log_info "Ключи получены через xray на $F_LABEL"
    else
        # Remnawave Node ещё не установлен — генерируем через openssl
        log_warn "remnanode не запущен — генерируем через openssl"
        KEYGEN_OUT=$(sshpass -p "$F_PASS" ssh $SSH_OPTS "$F_USER@$F_IP" bash <<'KEYGEN'
PRIV_PEM=$(openssl genpkey -algorithm X25519 2>/dev/null)
PRIVATE_KEY=$(echo "$PRIV_PEM" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
PUBLIC_KEY=$(echo "$PRIV_PEM" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
echo "PRIVATE_KEY=$PRIVATE_KEY"
echo "PUBLIC_KEY=$PUBLIC_KEY"
KEYGEN
)
        PRIVATE_KEY=$(echo "$KEYGEN_OUT" | grep "PRIVATE_KEY=" | cut -d= -f2)
        PUBLIC_KEY=$(echo "$KEYGEN_OUT" | grep "PUBLIC_KEY=" | cut -d= -f2)
        log_info "Ключи сгенерированы через openssl на $F_LABEL"
    fi

    # Генерируем shortId
    SHORT_ID=$(sshpass -p "$F_PASS" ssh $SSH_OPTS "$F_USER@$F_IP" "openssl rand -hex 4" 2>/dev/null | tr -d '[:space:]')
fi

if [[ -z "$PRIVATE_KEY" ]]; then
    log_warn "Не удалось сгенерировать ключи автоматически"
    PRIVATE_KEY="<СГЕНЕРИРУЙ: docker exec remnanode /usr/local/bin/xray x25519>"
    PUBLIC_KEY="<ПУБЛИЧНЫЙ_КЛЮЧ>"
    SHORT_ID="$(openssl rand -hex 4 2>/dev/null || echo 'aabbccdd')"
fi

# ================================================================
# Итоговый отчёт
# ================================================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ИТОГ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""

for node_config in "${NODES[@]}"; do
    IFS='|' read -r LABEL IP USER PASS <<< "$node_config"
    STATUS="${RESULTS[$LABEL]:-SKIPPED}"
    if [[ "$STATUS" == "OK" ]]; then
        echo -e "  ${GREEN}✓${NC}  $LABEL ($IP) — ${GREEN}OK${NC}"
    else
        echo -e "  ${RED}✗${NC}  $LABEL ($IP) — ${RED}$STATUS${NC}"
    fi
done

echo ""
echo -e "${CYAN}════ Config Profile для панели Remnawave ════${NC}"
echo -e "${YELLOW}  Один профиль — для всех нод${NC}"
echo ""
echo -e "  privateKey:  ${GREEN}$PRIVATE_KEY${NC}"
echo -e "  publicKey:   ${GREEN}$PUBLIC_KEY${NC}"
echo -e "  shortId:     ${GREEN}$SHORT_ID${NC}"
echo -e "  SNI:         ${GREEN}$SNI_DONOR${NC}"
echo ""
echo "  Вставь в панели: Xray config → Config Profiles → New"
echo ""

cat <<JSON_EOF
{
  "inbounds": [
    {
      "tag": "VLESS-REALITY",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [
          { "dest": $FALLBACK_PORT, "xver": 0 }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "dest": "${SNI_DONOR}:443",
          "serverNames": ["${SNI_DONOR}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ]
}
JSON_EOF

echo ""
echo -e "${CYAN}════ Следующие шаги ════${NC}"
echo ""
echo -e "  1. Скопируй JSON выше → панель Remnawave → Config Profiles"
echo -e "  2. Создай Host для каждой ноды:"
echo -e "     address = IP ноды, port = 443"
echo -e "     security = tls, fingerprint = chrome"
echo -e "     SNI = $SNI_DONOR"
echo -e "     publicKey = $PUBLIC_KEY"
echo -e "     shortId = $SHORT_ID"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
