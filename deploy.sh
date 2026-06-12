#!/bin/bash
set -euo pipefail

# Remnawave Node — REALITY Fallback + nginx  (v2)
# Параметры через env vars:
#   SNI_DONOR              донор для маскировки           (default: www.microsoft.com)
#   FALLBACK_PORT          порт nginx-fallback (localhost) (default: 8080)
#   NODE_API_PORT          порт Remnawave Node API         (default: 3010)
#   PANEL_IP               IP панели — Node API откроется только ему
#   ALLOW_NODE_API_PUBLIC  =1 чтобы осознанно открыть Node API всем (если PANEL_IP не задан)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ── Шаг 1: Проверки ──────────────────────────────────────────
log_step "Шаг 1: Проверки системы"
[[ $EUID -ne 0 ]] && { log_error "Запустите от root"; exit 1; }
log_info "root — OK"

[[ -f /etc/os-release ]] && . /etc/os-release || { log_error "Не удалось определить ОС"; exit 1; }
OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"
case "${OS_ID}-${OS_VER}" in
  ubuntu-22.04|ubuntu-24.04|debian-11|debian-12) log_info "ОС: $OS_ID $OS_VER — OK" ;;
  ubuntu-*|debian-*) log_warn "ОС $OS_ID $OS_VER не тестировалась — продолжаем" ;;
  *) log_error "Неподдерживаемая ОС: $OS_ID $OS_VER (нужен Ubuntu 22/24 или Debian 11/12)"; exit 1 ;;
esac

# Порт 443 займёт Xray (не nginx). Предупреждаем, если он уже кем-то занят.
if command -v ss &>/dev/null && ss -ltn 2>/dev/null | grep -q ':443 '; then
  log_warn "Порт 443 уже занят — убедитесь, что это Xray, а не сторонний сервис"
fi

# ── Шаг 2: Параметры ─────────────────────────────────────────
log_step "Шаг 2: Параметры"
SNI_DONOR="${SNI_DONOR:-www.microsoft.com}"
FALLBACK_PORT="${FALLBACK_PORT:-8080}"
NODE_API_PORT="${NODE_API_PORT:-3010}"
PANEL_IP="${PANEL_IP:-}"
ALLOW_NODE_API_PUBLIC="${ALLOW_NODE_API_PUBLIC:-0}"

# Реальный SSH-порт — чтобы не закрыть себе доступ через firewall.
# || true чтобы set -e/pipefail не падали если Port в sshd_config не задан (дефолт 22).
SSH_PORT="$( { grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null || true; } | awk '{print $2}' | head -n1)"
SSH_PORT="${SSH_PORT:-22}"

# DNS-резолверы для nginx: системные из /etc/resolv.conf, иначе публичные.
RESOLVERS="$( { awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null || true; } | grep -vE '^127\.|^::1' | head -n3 | tr '\n' ' ' || true)"
[[ -z "${RESOLVERS// }" ]] && RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9"

echo -e "  SNI-донор:     ${GREEN}$SNI_DONOR${NC}"
echo -e "  Fallback порт: ${GREEN}$FALLBACK_PORT${NC}"
echo -e "  Node API порт: ${GREEN}$NODE_API_PORT${NC}"
echo -e "  SSH порт:      ${GREEN}$SSH_PORT${NC}"
echo -e "  nginx resolver:${GREEN} $RESOLVERS${NC}"

if [[ -n "$PANEL_IP" ]]; then
  echo -e "  Panel IP:      ${GREEN}$PANEL_IP${NC} (Node API только с этого IP)"
elif [[ "$ALLOW_NODE_API_PUBLIC" == "1" ]]; then
  echo -e "  Panel IP:      ${YELLOW}не задан, ALLOW_NODE_API_PUBLIC=1 — Node API будет открыт ВСЕМ${NC}"
else
  log_error "PANEL_IP не задан, Node API порт $NODE_API_PORT не будет открыт наружу."
  log_error "Задайте PANEL_IP=<ip панели>  ИЛИ  ALLOW_NODE_API_PUBLIC=1 чтобы осознанно открыть всем."
  exit 1
fi

# ── Шаг 3: Пакеты ────────────────────────────────────────────
log_step "Шаг 3: Пакеты"
export DEBIAN_FRONTEND=noninteractive
timeout 300 apt-get update -y -q || { log_error "apt-get update завис или вернул ошибку"; exit 1; }
apt-get install -y -q nginx curl ufw iproute2 libnginx-mod-http-headers-more-filter
log_info "Пакеты установлены"

# ── Шаг 4: nginx ─────────────────────────────────────────────
log_step "Шаг 4: nginx"

# map в http-контексте: если донор не прислал Server — ставим правдоподобный дефолт,
# иначе пробрасываем подлинный Server донора (без пустых значений-сигнатур).
cat > /etc/nginx/conf.d/00-fallback-map.conf <<MAP_EOF
map \$upstream_http_server \$fallback_server {
    ""      "Microsoft-IIS/10.0";
    default \$upstream_http_server;
}
MAP_EOF

cat > /etc/nginx/sites-available/remnawave-fallback <<NGINX_EOF
# Xray REALITY fallback — принимает расшифрованный HTTP от Xray, отдаёт контент донора.
server {
    listen 127.0.0.1:${FALLBACK_PORT} default_server;
    server_name _;
    server_tokens off;
    access_log off;
    resolver ${RESOLVERS} ipv6=off valid=60s;

    location / {
        set \$sni_donor "${SNI_DONOR}";
        proxy_pass https://\$sni_donor;
        proxy_ssl_server_name on;
        proxy_ssl_name ${SNI_DONOR};
        proxy_ssl_verify off;
        proxy_set_header Host ${SNI_DONOR};
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header Accept \$http_accept;
        proxy_set_header Accept-Language \$http_accept_language;
        proxy_set_header Accept-Encoding \$http_accept_encoding;

        # Прячем ТОЛЬКО то, что выдаёт прокси-прослойку.
        # Подлинные заголовки донора (X-MSEdge-Ref, X-Azure-Ref, X-Cache и т.п.)
        # НЕ трогаем — они часть правдоподобного ответа Microsoft.
        proxy_hide_header Via;
        proxy_hide_header X-Powered-By;
        more_set_headers "Server: \$fallback_server";

        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }
}

# Публичный HTTP (порт 80) — это то, что реально сканируется на IP сервера.
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;
    access_log off;
    resolver ${RESOLVERS} ipv6=off valid=60s;

    location / {
        set \$sni_donor "${SNI_DONOR}";
        proxy_pass http://\$sni_donor;
        proxy_set_header Host ${SNI_DONOR};
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header Accept \$http_accept;
        proxy_set_header Accept-Language \$http_accept_language;
        proxy_hide_header Via;
        proxy_hide_header X-Powered-By;
        more_set_headers "Server: \$fallback_server";

        proxy_connect_timeout 10s;
        proxy_read_timeout 15s;
        proxy_send_timeout 10s;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/remnawave-fallback /etc/nginx/sites-enabled/remnawave-fallback
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>&1 || { log_error "Ошибка конфига nginx"; exit 1; }
log_info "Конфиг nginx создан"

# ── Шаг 5: Firewall ──────────────────────────────────────────
log_step "Шаг 5: Firewall"
if command -v ufw &>/dev/null; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}"/tcp comment "SSH"
    ufw allow 80/tcp  comment "HTTP fallback"
    ufw allow 443/tcp comment "Xray VLESS+REALITY"

    # Чистим старое правило Node API (и broad, и по IP), затем ставим заново.
    ufw delete allow "${NODE_API_PORT}"/tcp 2>/dev/null || true
    if [[ -n "$PANEL_IP" ]]; then
        ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp comment "Remnawave Node API (panel only)"
        log_info "UFW: Node API $NODE_API_PORT — только $PANEL_IP"
    else
        ufw allow "${NODE_API_PORT}"/tcp comment "Remnawave Node API (PUBLIC)"
        log_warn "UFW: Node API $NODE_API_PORT открыт ВСЕМ (ALLOW_NODE_API_PUBLIC=1)"
    fi
    ufw --force enable
    log_info "UFW: SSH($SSH_PORT), 80, 443 открыты"
else
    log_warn "ufw не найден — настройте firewall вручную (SSH порт: $SSH_PORT)"
fi

# ── Шаг 5.1: SSH баннер ──────────────────────────────────────
log_step "Шаг 5.1: SSH баннер"
SSHD_CONF="/etc/ssh/sshd_config"
# Примечание: DebianBanner no убирает лишь суффикс "-Debian". Версия OpenSSH
# всё равно отправляется в протокольном баннере — это косметика, не маскировка.
if grep -qE '^[[:space:]]*DebianBanner' "$SSHD_CONF" 2>/dev/null; then
    sed -i 's/^[[:space:]]*DebianBanner.*/DebianBanner no/' "$SSHD_CONF"
else
    echo "DebianBanner no" >> "$SSHD_CONF"
fi
sed -i 's/^[[:space:]]*Banner .*/Banner none/' "$SSHD_CONF"
systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
log_info "SSH: суффикс -Debian убран (версия OpenSSH по-прежнему видна)"

# ── Шаг 5.2: Remnawave Node порт ─────────────────────────────
if [[ -f /opt/remnanode/.env ]]; then
    log_step "Шаг 5.2: Remnawave NODE_PORT → $NODE_API_PORT"
    CURRENT_PORT="$(grep -E '^NODE_PORT=' /opt/remnanode/.env | cut -d= -f2 || echo "")"
    if [[ "$CURRENT_PORT" != "$NODE_API_PORT" ]]; then
        sed -i "s/^NODE_PORT=.*/NODE_PORT=$NODE_API_PORT/" /opt/remnanode/.env
        log_info "NODE_PORT: ${CURRENT_PORT:-<empty>} → $NODE_API_PORT"
        if command -v docker &>/dev/null && docker ps --filter name=remnanode --format '{{.Names}}' | grep -q remnanode; then
            ( cd /opt/remnanode && docker compose down && docker compose up -d )
            log_info "Контейнер remnanode перезапущен"
        fi
    else
        log_info "NODE_PORT уже $NODE_API_PORT"
    fi
fi

# ── Шаг 6: Запуск nginx ──────────────────────────────────────
log_step "Шаг 6: Запуск"
systemctl restart nginx
systemctl enable nginx >/dev/null 2>&1 || true
if systemctl is-active --quiet nginx; then
    log_info "nginx работает"
else
    log_error "nginx не запустился"
    exit 1
fi

# ── Шаг 7: Проверка ──────────────────────────────────────────
log_step "Шаг 7: Проверка"
sleep 1
CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://127.0.0.1:$FALLBACK_PORT/" 2>/dev/null || echo "000")"
case "$CODE" in
  200|301|302) log_info "Fallback → $CODE ($SNI_DONOR) — OK" ;;
  *) log_warn "Fallback → $CODE (ожидался 200/301/302; донор может резать серверные IP)" ;;
esac
log_info "Готово"
