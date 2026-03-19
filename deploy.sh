#!/bin/bash
set -euo pipefail

# ================================================================
# Remnawave Node — REALITY Fallback + nginx
# Маскирует VPN-сервер под настоящий веб-сайт
# Защита от активного зондирования ТСПУ (слои 3 и 4)
#
# Схема:
#   Клиент → Xray (443, VLESS+REALITY)
#       ├── VPN клиент → туннель
#       └── зондировщик → fallback → nginx (8080) → microsoft.com
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ================================================================
# ШАГ 1 — Проверки
# ================================================================
log_step "Шаг 1: Проверки системы"

if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен быть запущен от root"
    exit 1
fi
log_info "Запущен от root — OK"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
else
    log_error "Не удалось определить ОС"
    exit 1
fi

case "${OS_ID}-${OS_VERSION}" in
    ubuntu-22.04|ubuntu-24.04|debian-11|debian-12) ;;
    *) log_error "Неподдерживаемая ОС: $OS_ID $OS_VERSION"; exit 1 ;;
esac
log_info "ОС: $OS_ID $OS_VERSION — OK"

# ================================================================
# ШАГ 2 — Параметры
# ================================================================
log_step "Шаг 2: Параметры установки"

read -rp "SNI-донор для маскировки [www.microsoft.com]: " SNI_DONOR
SNI_DONOR=${SNI_DONOR:-www.microsoft.com}

read -rp "Порт nginx fallback [8080]: " FALLBACK_PORT
FALLBACK_PORT=${FALLBACK_PORT:-8080}

read -rp "Порт Remnawave Node API [3010]: " NODE_API_PORT
NODE_API_PORT=${NODE_API_PORT:-3010}

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  SNI-донор:       ${GREEN}$SNI_DONOR${NC}"
echo -e "  Fallback порт:   ${GREEN}$FALLBACK_PORT${NC}"
echo -e "  Node API порт:   ${GREEN}$NODE_API_PORT${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Схема:"
echo -e "  Клиент → Xray (443, VLESS+REALITY)"
echo -e "      ├── VPN клиент → туннель"
echo -e "      └── зондировщик → nginx ($FALLBACK_PORT) → $SNI_DONOR"
echo ""

read -rp "Продолжить? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    log_info "Установка отменена"
    exit 0
fi

# ================================================================
# ШАГ 3 — Установка пакетов
# ================================================================
log_step "Шаг 3: Установка пакетов"

apt-get update -y
apt-get install -y nginx curl wget ufw

log_info "Пакеты установлены"

# ================================================================
# ШАГ 4 — Конфиг nginx (fallback)
# ================================================================
log_step "Шаг 4: Конфигурация nginx"

cat > /etc/nginx/sites-available/remnawave-fallback <<NGINX_EOF
# ─────────────────────────────────────────────────────────────
# Remnawave — REALITY Fallback
# nginx слушает на 127.0.0.1:$FALLBACK_PORT
# Xray перенаправляет сюда зондировщиков / невалидные запросы
# ─────────────────────────────────────────────────────────────

server {
    listen 127.0.0.1:$FALLBACK_PORT;
    server_name _;

    server_tokens off;

    location / {
        proxy_pass https://$SNI_DONOR;
        proxy_ssl_server_name on;
        proxy_ssl_name $SNI_DONOR;
        proxy_set_header Host $SNI_DONOR;
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header Accept \$http_accept;
        proxy_set_header Accept-Language \$http_accept_language;
        proxy_set_header Accept-Encoding \$http_accept_encoding;

        # Убрать заголовки выдающие прокси/CDN
        proxy_hide_header X-Powered-By;
        proxy_hide_header X-Cache;
        proxy_hide_header Via;
        proxy_hide_header X-Amz-Cf-Id;
        proxy_hide_header X-Amz-Cf-Pop;
        proxy_hide_header X-MSEdge-Ref;
        proxy_hide_header X-Azure-Ref;

        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/remnawave-fallback /etc/nginx/sites-enabled/remnawave-fallback
rm -f /etc/nginx/sites-enabled/default

if ! nginx -t 2>&1; then
    log_error "Ошибка в конфиге nginx!"
    exit 1
fi

log_info "Конфиг nginx создан"

# ================================================================
# ШАГ 5 — Firewall
# ================================================================
log_step "Шаг 5: Настройка firewall"

if command -v ufw &>/dev/null; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "SSH"
    ufw allow 443/tcp comment "Xray VLESS+REALITY"
    ufw allow "$NODE_API_PORT"/tcp comment "Remnawave Node API"
    ufw --force enable
    log_info "Firewall настроен (SSH + 443 + $NODE_API_PORT)"
else
    log_warn "ufw не найден — настройте firewall вручную"
fi

# ================================================================
# ШАГ 6 — Запуск nginx
# ================================================================
log_step "Шаг 6: Запуск nginx"

systemctl restart nginx
systemctl enable nginx

if systemctl is-active --quiet nginx; then
    log_info "nginx запущен и работает"
else
    log_error "nginx не запустился!"
    exit 1
fi

# ================================================================
# ШАГ 7 — Проверки
# ================================================================
log_step "Шаг 7: Проверки"

sleep 1

FALLBACK_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://127.0.0.1:$FALLBACK_PORT/" 2>/dev/null || echo "000")
if [[ "$FALLBACK_CODE" == "200" || "$FALLBACK_CODE" == "301" || "$FALLBACK_CODE" == "302" ]]; then
    log_info "Fallback (127.0.0.1:$FALLBACK_PORT) → $FALLBACK_CODE ($SNI_DONOR) — OK"
else
    log_warn "Fallback → $FALLBACK_CODE (ожидался 200/301/302)"
    log_warn "$SNI_DONOR может блокировать запросы с серверных IP"
fi

# ================================================================
# ШАГ 8 — Итог
# ================================================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Установка завершена успешно${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  SNI-донор:      ${GREEN}$SNI_DONOR${NC}"
echo -e "  Fallback:       ${GREEN}127.0.0.1:$FALLBACK_PORT${NC}"
echo -e "  Firewall:       ${GREEN}22, 443, $NODE_API_PORT${NC}"
echo ""
echo -e "${CYAN}════ Схема ════${NC}"
echo ""
echo -e "  Клиент → Xray (443, VLESS+REALITY)"
echo -e "      ├── VPN клиент → туннель → интернет"
echo -e "      └── зондировщик → fallback → nginx → $SNI_DONOR"
echo ""
echo -e "${CYAN}════ Что дальше ════${NC}"
echo ""
echo -e "  1. Установите Remnawave Node (docker compose)"
echo ""
echo -e "  2. В панели Remnawave создайте Config Profile:"
echo ""
echo -e "     {\"inbounds\": [{"
echo -e "       \"tag\": \"VLESS-REALITY\","
echo -e "       \"port\": 443,"
echo -e "       \"protocol\": \"vless\","
echo -e "       \"settings\": {"
echo -e "         \"clients\": [],"
echo -e "         \"decryption\": \"none\","
echo -e "         \"fallbacks\": [{\"dest\": \"$FALLBACK_PORT\", \"xver\": 0}]"
echo -e "       },"
echo -e "       \"streamSettings\": {"
echo -e "         \"network\": \"raw\","
echo -e "         \"security\": \"reality\","
echo -e "         \"realitySettings\": {"
echo -e "           \"dest\": \"$SNI_DONOR:443\","
echo -e "           \"serverNames\": [\"$SNI_DONOR\"],"
echo -e "           \"privateKey\": \"<СГЕНЕРИРУЙТЕ>\","
echo -e "           \"shortIds\": [\"<СГЕНЕРИРУЙТЕ>\"]"
echo -e "         }"
echo -e "       }"
echo -e "     }]}"
echo ""
echo -e "  3. Привяжите профиль к ноде, создайте Host"
echo ""
echo -e "  4. Проверьте подключение через клиент"
echo ""
echo -e "${CYAN}════ Проверки ════${NC}"
echo ""
echo -e "  # Fallback отдаёт $SNI_DONOR:"
echo -e "  curl http://127.0.0.1:$FALLBACK_PORT/"
echo ""
echo -e "  # Зондировщик видит Microsoft:"
echo -e "  curl -k --resolve $SNI_DONOR:443:$(hostname -I | awk '{print $1}') https://$SNI_DONOR/"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
