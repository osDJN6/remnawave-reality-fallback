#!/bin/bash
set -euo pipefail

# Remnawave Node — REALITY Fallback + nginx  (v4)
# Параметры через env vars:
#   SNI_DONOR              донор для маскировки            (default: www.microsoft.com)
#   FALLBACK_PORT          порт nginx-fallback (localhost) (default: 8080)
#   NODE_API_PORT          порт Remnawave Node API         (default: 3010)
#   PANEL_IP               IP панели — Node API откроется только ему
#   ALLOW_NODE_API_PUBLIC  =1 чтобы осознанно открыть Node API всем (если PANEL_IP не задан)
#   ENABLE_FAIL2BAN        =0 чтобы пропустить установку fail2ban (default: 1)
#   ENABLE_SYSCTL          =0 чтобы пропустить сетевой тюнинг BBR (default: 1)
#   ENABLE_CACHE           =0 чтобы пропустить micro-cache донора (default: 1)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

TS="$(date +%Y%m%d-%H%M%S)"

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
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-1}"
ENABLE_SYSCTL="${ENABLE_SYSCTL:-1}"
ENABLE_CACHE="${ENABLE_CACHE:-1}"

# Валидация PANEL_IP (если задан) — простая проверка на IPv4/IPv6-подобный вид.
if [[ -n "$PANEL_IP" ]]; then
  if ! [[ "$PANEL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$PANEL_IP" =~ : ]]; then
    log_error "PANEL_IP='$PANEL_IP' не похож на IP-адрес"; exit 1
  fi
fi

# Реальный SSH-порт — чтобы не закрыть себе доступ через firewall.
# || true чтобы set -e/pipefail не падали если Port в sshd_config не задан (дефолт 22).
SSH_PORT="$( { grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null || true; } | awk '{print $2}' | head -n1)"
SSH_PORT="${SSH_PORT:-22}"

# DNS-резолверы для nginx: системные из /etc/resolv.conf, иначе публичные.
RESOLVERS="$( { awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null || true; } | grep -vE '^127\.|^::1' | head -n3 | tr '\n' ' ' || true)"
[[ -z "${RESOLVERS// }" ]] && RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9"

# Есть ли у сервера глобальный IPv6 — от этого зависит, слушать ли :80 на v6.
HAS_IPV6=0
if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then HAS_IPV6=1; fi

echo -e "  SNI-донор:     ${GREEN}$SNI_DONOR${NC}"
echo -e "  Fallback порт: ${GREEN}$FALLBACK_PORT${NC}"
echo -e "  Node API порт: ${GREEN}$NODE_API_PORT${NC}"
echo -e "  SSH порт:      ${GREEN}$SSH_PORT${NC}"
echo -e "  nginx resolver:${GREEN} $RESOLVERS${NC}"
echo -e "  IPv6:          ${GREEN}$([[ $HAS_IPV6 == 1 ]] && echo "есть — слушаем :80 на v6" || echo "нет")${NC}"
echo -e "  fail2ban:      ${GREEN}$([[ $ENABLE_FAIL2BAN == 1 ]] && echo "вкл" || echo "выкл")${NC}"
echo -e "  BBR sysctl:    ${GREEN}$([[ $ENABLE_SYSCTL == 1 ]] && echo "вкл" || echo "выкл")${NC}"
echo -e "  micro-cache:   ${GREEN}$([[ $ENABLE_CACHE == 1 ]] && echo "вкл" || echo "выкл")${NC}"

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
PKGS="nginx curl ufw iproute2 libnginx-mod-http-headers-more-filter"
[[ "$ENABLE_FAIL2BAN" == "1" ]] && PKGS="$PKGS fail2ban"
apt-get install -y -q $PKGS
log_info "Пакеты установлены"

# ── Шаг 3.1: Сетевой тюнинг (BBR + fastopen) ─────────────────
if [[ "$ENABLE_SYSCTL" == "1" ]]; then
  log_step "Шаг 3.1: Сетевой тюнинг"
  cat > /etc/sysctl.d/99-remnawave-fallback.conf <<'SYSCTL_EOF'
# Congestion control + queue discipline
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# TCP Fast Open (клиент+сервер)
net.ipv4.tcp_fastopen = 3
# Меньше задержки/джиттер на хендшейках под нагрузкой
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
SYSCTL_EOF
  if sysctl --system >/dev/null 2>&1; then
    ACTIVE_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    log_info "sysctl применён (congestion control: $ACTIVE_CC)"
    [[ "$ACTIVE_CC" != "bbr" ]] && log_warn "BBR не активировался — возможно, нужен модуль tcp_bbr/перезагрузка"
  else
    log_warn "sysctl --system вернул ошибку — пропускаем"
  fi
fi

# ── Шаг 4: nginx ─────────────────────────────────────────────
log_step "Шаг 4: nginx"

# http-контекст: map для Server + (опционально) micro-cache донора и rate-limit зона.
{
  cat <<'MAP_EOF'
# Пробрасываем ПОДЛИННЫЙ Server донора. Если донор Server не прислал —
# $fallback_server пуст, и more_set_headers с пустым значением УБИРАЕТ заголовок.
# Так мы не выдумываем неверный Server (это была бы сигнатура) и не светим nginx.
map $upstream_http_server $fallback_server {
    default $upstream_http_server;
}
MAP_EOF

  if [[ "$ENABLE_CACHE" == "1" ]]; then
    cat <<'CACHE_EOF'

# Короткий кэш ответа донора → ровная латентность и консистентный ответ на пробы/скан.
proxy_cache_path /var/cache/nginx/fallback levels=1:2 keys_zone=fallback_cache:10m
                 max_size=128m inactive=120s use_temp_path=off;

# Анти-абьюз для публичного :80 (открытый прокси не должен молотить бесконечно).
limit_req_zone $binary_remote_addr zone=fallback80:10m rate=20r/s;
CACHE_EOF
  fi
} > /etc/nginx/conf.d/00-fallback-http.conf

# Удаляем старый одиночный map-файл от предыдущих версий, если он остался.
rm -f /etc/nginx/conf.d/00-fallback-map.conf

if [[ "$ENABLE_CACHE" == "1" ]]; then
  mkdir -p /var/cache/nginx/fallback
  chown -R www-data:www-data /var/cache/nginx/fallback 2>/dev/null || true
fi

# Динамический набор listen-директив для :80 (+ IPv6 при наличии).
LISTEN80="    listen 80 default_server;"
[[ $HAS_IPV6 == 1 ]] && LISTEN80="${LISTEN80}
    listen [::]:80 default_server;"

# Опциональные кэш-директивы в location {}.
CACHE_LOC=""
CACHE_LOC_80_EXTRA=""
if [[ "$ENABLE_CACHE" == "1" ]]; then
  CACHE_LOC=$'        proxy_cache fallback_cache;\n        proxy_cache_methods GET HEAD;\n        proxy_cache_valid 200 301 302 60s;\n        proxy_cache_key "$scheme$host$request_uri";\n        proxy_ignore_headers Set-Cookie Cache-Control Expires;\n        proxy_hide_header Set-Cookie;'
  # X-Cache-Status только во внутреннем fallback (:8080) — туда ходит лишь Xray,
  # клиент видит уже расшифрованный поток. На публичном :80 этот заголовок
  # был бы новой сигнатурой (у Microsoft его нет).
  CACHE_LOC_80_EXTRA=$'        limit_req zone=fallback80 burst=40 nodelay;'
fi

cat > /etc/nginx/sites-available/remnawave-fallback <<NGINX_EOF
# Xray REALITY fallback — принимает расшифрованный HTTP от Xray, отдаёт контент донора.
server {
    listen 127.0.0.1:${FALLBACK_PORT} default_server;
    server_name _;
    server_tokens off;
    access_log off;
    resolver ${RESOLVERS} ipv6=off valid=60s;

    # Server-level дефолт: применяется ко всем ответам, включая ошибки nginx
    # (405 на TRACE/PUT/DELETE, 400/413/414/494 и т.п.) — иначе ТСПУ ловит
    # "Server: nginx" одним TRACE-запросом, сигнатура мгновенная.
    more_set_headers "Server: AkamaiNetStorage";

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

${CACHE_LOC}

        # Прячем ТОЛЬКО то, что выдаёт прокси-прослойку.
        # Подлинные заголовки донора (X-MSEdge-Ref, X-Azure-Ref, X-Cache и т.п.) НЕ трогаем.
        proxy_hide_header Via;
        proxy_hide_header X-Powered-By;
        # Для нормальных проксированных ответов — пробрасываем подлинный Server донора.
        more_set_headers "Server: \$fallback_server";

        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }
}

# Публичный HTTP (порт 80) — это то, что реально сканируется на IP сервера.
server {
${LISTEN80}
    server_name _;
    server_tokens off;
    access_log off;
    resolver ${RESOLVERS} ipv6=off valid=60s;

    # См. комментарий выше — нужен для ошибок nginx (TRACE → 405 и т.п.).
    more_set_headers "Server: AkamaiNetStorage";

    location / {
${CACHE_LOC_80_EXTRA}

        set \$sni_donor "${SNI_DONOR}";
        proxy_pass http://\$sni_donor;
        proxy_set_header Host ${SNI_DONOR};
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header Accept \$http_accept;
        proxy_set_header Accept-Language \$http_accept_language;

${CACHE_LOC}

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
cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.${TS}" 2>/dev/null && log_info "Бэкап: ${SSHD_CONF}.bak.${TS}"
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

# ── Шаг 5.2: fail2ban для SSH ────────────────────────────────
if [[ "$ENABLE_FAIL2BAN" == "1" ]] && command -v fail2ban-server &>/dev/null; then
    log_step "Шаг 5.2: fail2ban"
    cat > /etc/fail2ban/jail.d/sshd-remnawave.conf <<F2B_EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
F2B_EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban 2>/dev/null || true
    log_info "fail2ban: jail sshd на порту $SSH_PORT (5 попыток / 10м → бан 1ч)"
fi

# ── Шаг 5.3: Remnawave Node порт ─────────────────────────────
if [[ -f /opt/remnanode/.env ]]; then
    log_step "Шаг 5.3: Remnawave NODE_PORT → $NODE_API_PORT"
    cp -a /opt/remnanode/.env "/opt/remnanode/.env.bak.${TS}" && log_info "Бэкап: /opt/remnanode/.env.bak.${TS}"
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

# ── Шаг 7: Проверки ──────────────────────────────────────────
log_step "Шаг 7: Проверки"
sleep 1

# 7.1 Локальный fallback (nginx 8080)
CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://127.0.0.1:$FALLBACK_PORT/" 2>/dev/null || echo "000")"
case "$CODE" in
  200|301|302) log_info "Fallback (8080) → $CODE ($SNI_DONOR) — OK" ;;
  *) log_warn "Fallback (8080) → $CODE (ожидался 200/301/302; донор может резать серверные IP)" ;;
esac

# 7.2 Доступность донора REALITY (dest на :443) с самого сервера —
#     это другой слой: именно сюда REALITY уводит зондировщиков без ключа.
# -4: force IPv4 (как nginx с resolver ipv6=off — иначе на хостах с IPv6 DNS
#     может вернуть AAAA и упасть в таймаут, дав ложно-негативную проверку).
DCODE="$(curl -s -4 -o /dev/null -w '%{http_code}' --max-time 10 "https://$SNI_DONOR/" 2>/dev/null || echo "000")"
case "$DCODE" in
  200|201|301|302|307|308)
    log_info "Донор $SNI_DONOR:443 → $DCODE — доступен" ;;
  *)
    log_warn "Донор $SNI_DONOR:443 → $DCODE — недоступен/нестандартный ответ. REALITY dest может не работать." ;;
esac

# 7.3 Если кэш включён — прогреем и убедимся что второй запрос идёт из кэша.
if [[ "$ENABLE_CACHE" == "1" ]]; then
    curl -s -o /dev/null --connect-timeout 5 --max-time 8 "http://127.0.0.1:$FALLBACK_PORT/" >/dev/null 2>&1 || true
    HIT="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "http://127.0.0.1:$FALLBACK_PORT/" 2>/dev/null || echo "000")"
    # Прогрев успешен если второй запрос быстрый и 200. Точный HIT-статус не светим клиенту.
    [[ "$HIT" == "200" ]] && log_info "micro-cache прогрет (повторный запрос → $HIT)"
fi

# ── Шаг 8: Сводка ────────────────────────────────────────────
INFO_DIR="/opt/remnawave-fallback"
mkdir -p "$INFO_DIR"
cat > "$INFO_DIR/install-info.txt" <<INFO_EOF
Remnawave REALITY Fallback — установка $TS
SNI_DONOR=$SNI_DONOR
FALLBACK_PORT=$FALLBACK_PORT
NODE_API_PORT=$NODE_API_PORT
SSH_PORT=$SSH_PORT
PANEL_IP=${PANEL_IP:-<public>}
IPV6=$([[ $HAS_IPV6 == 1 ]] && echo yes || echo no)
RESOLVERS=$RESOLVERS
ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN
ENABLE_SYSCTL=$ENABLE_SYSCTL
ENABLE_CACHE=$ENABLE_CACHE
INFO_EOF
log_info "Сводка: $INFO_DIR/install-info.txt"
log_info "Готово"
