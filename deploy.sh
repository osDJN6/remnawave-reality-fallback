#!/bin/bash
set -euo pipefail

# Remnawave Node — REALITY Fallback + nginx
# Запускается автоматически через deploy-all.sh
# Параметры через env vars: SNI_DONOR, FALLBACK_PORT, NODE_API_PORT

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
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
case "${OS_ID}-${OS_VER}" in
    ubuntu-22.04|ubuntu-24.04|debian-11|debian-12) log_info "ОС: $OS_ID $OS_VER — OK" ;;
    ubuntu-*|debian-*) log_warn "ОС $OS_ID $OS_VER не тестировалась — продолжаем" ;;
    *) log_error "Неподдерживаемая ОС: $OS_ID $OS_VER (нужен Ubuntu 22/24 или Debian 11/12)"; exit 1 ;;
esac

# ── Шаг 2: Параметры ─────────────────────────────────────────
log_step "Шаг 2: Параметры"

SNI_DONOR="${SNI_DONOR:-www.microsoft.com}"
FALLBACK_PORT="${FALLBACK_PORT:-8080}"
NODE_API_PORT="${NODE_API_PORT:-3010}"
PANEL_IP="${PANEL_IP:-}"

echo -e "  SNI-донор:     ${GREEN}$SNI_DONOR${NC}"
echo -e "  Fallback порт: ${GREEN}$FALLBACK_PORT${NC}"
echo -e "  Node API порт: ${GREEN}$NODE_API_PORT${NC}"
if [[ -n "$PANEL_IP" ]]; then
    echo -e "  Panel IP:      ${GREEN}$PANEL_IP${NC} (Node API только с этого IP)"
else
    echo -e "  Panel IP:      ${YELLOW}не задан — Node API открыт для всех${NC}"
fi

# ── Шаг 3: Установка пакетов ─────────────────────────────────
log_step "Шаг 3: Пакеты"
export DEBIAN_FRONTEND=noninteractive
timeout 300 apt-get update -y -q || { log_error "apt-get update завис или вернул ошибку"; exit 1; }
apt-get install -y -q nginx curl ufw libnginx-mod-http-headers-more-filter
log_info "Пакеты установлены"

# ── Шаг 4: Конфиг nginx ──────────────────────────────────────
log_step "Шаг 4: nginx"

cat > /etc/nginx/sites-available/remnawave-fallback <<NGINX_EOF
# Xray REALITY fallback — HTTPS (любой SNI через localhost)
server {
    listen 127.0.0.1:${FALLBACK_PORT} default_server;
    server_name _;
    server_tokens off;
    resolver 8.8.8.8 8.8.4.4 ipv6=off;

    location / {
        proxy_pass https://${SNI_DONOR};
        proxy_ssl_server_name on;
        proxy_ssl_name ${SNI_DONOR};
        proxy_ssl_verify off;
        proxy_set_header Host ${SNI_DONOR};
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header Accept \$http_accept;
        proxy_set_header Accept-Language \$http_accept_language;
        proxy_set_header Accept-Encoding \$http_accept_encoding;
        proxy_hide_header X-Powered-By;
        proxy_hide_header X-Cache;
        proxy_hide_header Via;
        proxy_hide_header X-MSEdge-Ref;
        proxy_hide_header X-Azure-Ref;
        more_set_headers "Server: \$upstream_http_server";
        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }
}

# Публичный HTTP (порт 80) — проксируем на SNI-донор
# Цензор видит настоящие заголовки Microsoft, без следов nginx
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;
    resolver 8.8.8.8 8.8.4.4 ipv6=off;

    location / {
        proxy_pass http://${SNI_DONOR};
        proxy_set_header Host ${SNI_DONOR};
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header Accept \$http_accept;
        proxy_set_header Accept-Language \$http_accept_language;
        proxy_hide_header X-Powered-By;
        proxy_hide_header Via;
        more_set_headers "Server: \$upstream_http_server";
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
    ufw allow 22/tcp comment "SSH"
    ufw allow 80/tcp comment "HTTP fallback"
    ufw allow 443/tcp comment "Xray VLESS+REALITY"
    # Node API — только с IP панели если задан, иначе открыт для всех
    ufw delete allow "$NODE_API_PORT"/tcp 2>/dev/null || true
    if [[ -n "$PANEL_IP" ]]; then
        ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp comment "Remnawave Node API (panel only)"
        log_info "UFW: Node API порт $NODE_API_PORT — только $PANEL_IP"
    else
        ufw allow "$NODE_API_PORT"/tcp comment "Remnawave Node API"
        log_info "UFW: Node API порт $NODE_API_PORT — открыт для всех"
    fi
    ufw --force enable
    log_info "UFW: 22, 80, 443 открыты"
else
    log_warn "ufw не найден — настройте firewall вручную"
fi

# ── Шаг 5.1: SSH hardening ───────────────────────────────────
log_step "Шаг 5.1: SSH hardening"
SSHD_CONF="/etc/ssh/sshd_config"
# Скрываем версию OpenSSH в баннере
if grep -q "^DebianBanner" "$SSHD_CONF" 2>/dev/null; then
    sed -i 's/^DebianBanner.*/DebianBanner no/' "$SSHD_CONF"
else
    echo "DebianBanner no" >> "$SSHD_CONF"
fi
# Убираем баннер-файл если есть
sed -i 's/^Banner .*/Banner none/' "$SSHD_CONF"
systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
log_info "SSH: версия ОС в баннере скрыта"

# ── Шаг 5.2: Remnawave Node порт ──────────────────────────────
if [[ -f /opt/remnanode/.env ]]; then
    log_step "Шаг 5.2: Remnawave Node NODE_PORT → $NODE_API_PORT"
    CURRENT_PORT=$(grep -E '^NODE_PORT=' /opt/remnanode/.env | cut -d= -f2 || echo "")
    if [[ "$CURRENT_PORT" != "$NODE_API_PORT" ]]; then
        sed -i "s/^NODE_PORT=.*/NODE_PORT=$NODE_API_PORT/" /opt/remnanode/.env
        log_info "NODE_PORT обновлён: $CURRENT_PORT → $NODE_API_PORT"
        if command -v docker &>/dev/null && docker ps --filter name=remnanode --format '{{.Names}}' | grep -q remnanode; then
            cd /opt/remnanode && docker compose down && docker compose up -d
            cd - >/dev/null
            log_info "Контейнер remnanode перезапущен"
        fi
    else
        log_info "NODE_PORT уже $NODE_API_PORT"
    fi
fi

# ── Шаг 6: Запуск nginx ──────────────────────────────────────
log_step "Шаг 6: Запуск"
systemctl restart nginx
systemctl enable nginx
if systemctl is-active --quiet nginx; then
    log_info "nginx работает"
else
    log_error "nginx не запустился"
    exit 1
fi

# ── Шаг 7: Проверка ──────────────────────────────────────────
log_step "Шаг 7: Проверка"
sleep 1
CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://127.0.0.1:$FALLBACK_PORT/" 2>/dev/null || echo "000")
if [[ "$CODE" == "200" || "$CODE" == "301" || "$CODE" == "302" ]]; then
    log_info "Fallback → $CODE ($SNI_DONOR) — OK"
else
    log_warn "Fallback → $CODE (ожидался 200/301/302 — $SNI_DONOR может блокировать серверные IP)"
fi

log_info "Готово"
