#!/bin/bash
# =============================================================================
# setup_hysteria2.sh — Настройка VPS + установка Hysteria2
# =============================================================================
# Использование:
#   bash setup_hysteria2.sh \
#     --domain      ваш_домен           (например: myvpn.mooo.com) \
#     --email       ваш@email.com       (для Let's Encrypt сертификата) \
#     --user        имя_системного_пользователя \
#     --user-pass   пароль_юзера \
#     --root-pass   пароль_рута         (если не задан — генерируется автоматически) \
#     --ssh-port    порт_ssh            (из диапазона 1024-65535) \
#     --vpn-user    имя_vpn_юзера       (по умолчанию: Admin) \
#     --vpn-pass    пароль_vpn          (если не задан — генерируется автоматически)
#
# Скрипт должен запускаться от root на чистом Debian 12 / Ubuntu 24
# =============================================================================

set -euo pipefail

# ─── Цвета для вывода ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${CYAN}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗] ОШИБКА:${NC} $*" >&2; exit 1; }

# ─── Значения по умолчанию ───────────────────────────────────────────────────
DOMAIN=""
EMAIL=""
NEW_USER=""
USER_PASS=""
ROOT_PASS=""
SSH_PORT=""
VPN_USER="Admin"
VPN_PASS=""

# ─── Парсинг аргументов ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    DOMAIN="$2";    shift 2 ;;
    --email)     EMAIL="$2";     shift 2 ;;
    --user)      NEW_USER="$2";  shift 2 ;;
    --user-pass) USER_PASS="$2"; shift 2 ;;
    --root-pass) ROOT_PASS="$2"; shift 2 ;;
    --ssh-port)  SSH_PORT="$2";  shift 2 ;;
    --vpn-user)  VPN_USER="$2";  shift 2 ;;
    --vpn-pass)  VPN_PASS="$2";  shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ─── Проверка обязательных аргументов ────────────────────────────────────────
[[ -z "$DOMAIN"    ]] && die "Укажите --domain"
[[ -z "$EMAIL"     ]] && die "Укажите --email"
[[ -z "$NEW_USER"  ]] && die "Укажите --user"
[[ -z "$USER_PASS" ]] && die "Укажите --user-pass"
[[ -z "$SSH_PORT"  ]] && die "Укажите --ssh-port"

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
  die "Порт SSH должен быть числом от 1024 до 65535"
fi

# Генерация паролей если не заданы
if [[ -z "$ROOT_PASS" ]]; then
  ROOT_PASS=$(tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 20)
  warn "Пароль root не задан, сгенерирован автоматически: $ROOT_PASS"
fi

if [[ -z "$VPN_PASS" ]]; then
  VPN_PASS=$(openssl rand -hex 16)
  warn "Пароль VPN не задан, сгенерирован автоматически: $VPN_PASS"
fi

# Проверка что запущен от root
[[ $EUID -ne 0 ]] && die "Скрипт должен запускаться от root"

# ─── Получение IPv4 адреса сервера ───────────────────────────────────────────
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 api.ipify.org || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
[[ -z "$SERVER_IP" ]] && die "Не удалось определить IP сервера"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Настройка VPS + Hysteria2                        ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

# ─── 1. Смена пароля root ─────────────────────────────────────────────────────
info "Шаг 1/7: Смена пароля root..."
echo "root:${ROOT_PASS}" | chpasswd
log "Пароль root изменён"

# ─── 2. Обновление пакетов ───────────────────────────────────────────────────
info "Шаг 2/7: Обновление пакетов (может занять 5-10 минут)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
log "Пакеты обновлены"

# ─── 3. Создание нового пользователя ─────────────────────────────────────────
info "Шаг 3/7: Создание пользователя '${NEW_USER}'..."
if id "$NEW_USER" &>/dev/null; then
  warn "Пользователь '$NEW_USER' уже существует, обновляю пароль..."
  echo "${NEW_USER}:${USER_PASS}" | chpasswd
else
  adduser --gecos "" --disabled-password "$NEW_USER"
  echo "${NEW_USER}:${USER_PASS}" | chpasswd
fi
usermod -aG sudo "$NEW_USER"
log "Пользователь '${NEW_USER}' создан и добавлен в sudo"

# ─── 4. Настройка SSH ────────────────────────────────────────────────────────
info "Шаг 4/7: Настройка SSH (порт ${SSH_PORT}, запрет входа root)..."
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

sed -i "s/^#*Port .*/Port ${SSH_PORT}/" "$SSHD_CONFIG"
grep -q "^Port " "$SSHD_CONFIG" || echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"

sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
grep -q "^PermitRootLogin " "$SSHD_CONFIG" || echo "PermitRootLogin no" >> "$SSHD_CONFIG"

systemctl restart sshd
log "SSH перенастроен: порт ${SSH_PORT}, вход root запрещён"

# ─── 5. Установка Fail2ban ───────────────────────────────────────────────────
info "Шаг 5/7: Установка Fail2ban..."
apt-get install -y -q rsyslog fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
EOF

systemctl restart fail2ban
systemctl enable fail2ban
log "Fail2ban установлен и запущен"

# ─── 6. Установка Hysteria2 ───────────────────────────────────────────────────
info "Шаг 6/7: Установка Hysteria2..."

# Проверка привязки домена
info "Проверка привязки домена ${DOMAIN} к IP ${SERVER_IP}..."
DOMAIN_IP=$(dig +short -t A "$DOMAIN" 2>/dev/null | tail -1 || getent ahostsv4 "$DOMAIN" | awk '{print $1}' | head -1 || echo "")
if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
  warn "Домен ${DOMAIN} указывает на ${DOMAIN_IP:-не определён}, а не на ${SERVER_IP}."
  warn "Убедитесь что домен привязан к серверу. Продолжаю через 10 секунд..."
  sleep 10
fi

# Установка Hysteria2
set +e
bash <(curl -fsSL https://get.hy2.sh/)
HY2_EXIT=$?
set -e
[[ $HY2_EXIT -ne 0 ]] && warn "Hysteria2 installer вернул код ${HY2_EXIT}, продолжаю..."
log "Hysteria2 установлен"

# Создание сайта-заглушки (случайный выбор из 5 вариантов)
info "Создание сайта-заглушки..."
mkdir -p /var/www/masq

# ── 5 вариантов заглушек ──────────────────────────────────────────────────────

MASQ_1='<!DOCTYPE html><html><head><meta charset="utf-8"><title>Please wait</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.dots{display:flex;gap:15px;margin-bottom:30px}.d{width:20px;height:20px;background:#fff;border-radius:50%;animation:b 1.4s infinite ease-in-out both}.d:nth-child(1){animation-delay:-0.32s}.d:nth-child(2){animation-delay:-0.16s}@keyframes b{0%,80%,100%{transform:scale(0);opacity:0.2}40%{transform:scale(1);opacity:1}}.t{color:#555;font-size:14px;letter-spacing:2px;font-weight:600}</style></head><body><div class="dots"><div class="d"></div><div class="d"></div><div class="d"></div></div><div class="t">RETRYING CONNECTION</div></body></html>'

# Nginx-стиль: 502 Bad Gateway
MASQ_2='<!DOCTYPE html><html><head><meta charset="utf-8"><title>502 Bad Gateway</title><style>body{margin:0;font-family:sans-serif;background:#fff;color:#333;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh}h1{font-size:36px;font-weight:700;margin:0 0 8px}p{font-size:14px;color:#777;margin:0}hr{border:none;border-top:1px solid #eee;width:400px;margin:20px 0}.srv{font-size:12px;color:#aaa}</style></head><body><h1>502 Bad Gateway</h1><hr><p class="srv">nginx/1.24.0</p></body></html>'

# Cloudflare-стиль: проверка браузера
MASQ_3='<!DOCTYPE html><html><head><meta charset="utf-8"><title>Just a moment...</title><style>*{box-sizing:border-box}body{margin:0;padding:0;background:#f6f6f6;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh}.wrap{background:#fff;border-radius:8px;padding:48px 40px;text-align:center;max-width:460px;width:90%;box-shadow:0 2px 12px rgba(0,0,0,.08)}.logo{font-size:28px;font-weight:700;color:#f38020;margin-bottom:24px}.title{font-size:20px;font-weight:600;color:#1d1d1d;margin-bottom:8px}.sub{font-size:14px;color:#6b6b6b;margin-bottom:32px}.spinner{width:36px;height:36px;border:3px solid #e8e8e8;border-top-color:#f38020;border-radius:50%;animation:spin .8s linear infinite;margin:0 auto}.ray{font-size:11px;color:#aaa;margin-top:28px}@keyframes spin{to{transform:rotate(360deg)}}</style></head><body><div class="wrap"><div class="logo">&#x2601; Cloudflare</div><div class="title">Checking your browser</div><div class="sub">This process is automatic. Your browser will redirect shortly.</div><div class="spinner"></div><div class="ray">Performance &amp; security by Cloudflare</div></div></body></html>'

# Простая страница обслуживания (Maintenance)
MASQ_4='<!DOCTYPE html><html><head><meta charset="utf-8"><title>Maintenance</title><style>body{margin:0;background:#0f172a;color:#94a3b8;font-family:ui-monospace,monospace;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;gap:16px}.code{font-size:72px;font-weight:700;color:#1e293b;line-height:1}.msg{font-size:13px;letter-spacing:3px;text-transform:uppercase}.bar{width:200px;height:2px;background:#1e293b;border-radius:1px;overflow:hidden;position:relative}.bar::after{content:"";position:absolute;left:-50%;width:50%;height:100%;background:#3b82f6;animation:slide 1.6s ease-in-out infinite}@keyframes slide{0%{left:-50%}100%{left:150%}}</style></head><body><div class="code">503</div><div class="msg">Service Unavailable</div><div class="bar"></div></body></html>'

# Минималистичная страница с пульсирующим кольцом
MASQ_5='<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title><style>body{margin:0;background:#fafafa;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;font-family:sans-serif;gap:24px}.ring{width:48px;height:48px;border-radius:50%;border:3px solid #e5e7eb;border-top:3px solid #111;animation:spin .9s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}.txt{font-size:13px;color:#9ca3af;letter-spacing:1px}</style></head><body><div class="ring"></div><div class="txt">Loading, please wait&hellip;</div></body></html>'

# ── Случайный выбор ───────────────────────────────────────────────────────────
MASQ_INDEX=$(( (RANDOM % 5) + 1 ))
MASQ_NAMES=("" "Retrying connection" "502 Bad Gateway" "Cloudflare check" "503 Maintenance" "Minimal spinner")

eval "MASQ_HTML=\$MASQ_${MASQ_INDEX}"
echo "$MASQ_HTML" > /var/www/masq/index.html

log "Сайт-заглушка создан: вариант ${MASQ_INDEX} — ${MASQ_NAMES[$MASQ_INDEX]}"

# Запись конфигурации
info "Запись конфигурации Hysteria2..."
cat > /etc/hysteria/config.yaml <<EOF
listen: 0.0.0.0:443

acme:
  type: http
  domains:
    - ${DOMAIN}
  email: ${EMAIL}

auth:
  type: userpass
  userpass:
    ${VPN_USER}: ${VPN_PASS}

masquerade:
  type: file
  file:
    dir: /var/www/masq
  listenHTTP: :80
  listenHTTPS: :443
  forceHTTPS: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
log "Конфигурация записана"

# Запуск службы
systemctl daemon-reload
systemctl enable --now hysteria-server.service
log "Hysteria2 запущен и добавлен в автозагрузку"

# ─── 7. Настройка UFW ────────────────────────────────────────────────────────
info "Шаг 7/7: Настройка UFW Firewall..."
apt-get install -y -q ufw
ufw --force reset

ufw allow OpenSSH
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp

ufw --force enable
log "UFW настроен и включён"

# ─── Формирование hy2 конфига ─────────────────────────────────────────────────
HY2_CONFIG="hy2://${VPN_USER}:${VPN_PASS}@${DOMAIN}:443?sni=${DOMAIN}&alpn=h3&insecure=0&allowInsecure=0#Hysteria2-${DOMAIN}"

# ─── Итоговый вывод ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         НАСТРОЙКА ЗАВЕРШЕНА — СОХРАНИТЕ ЭТО     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Remote Server Settings:"
echo "IP              - ${SERVER_IP}"
echo "SSH port        - ${SSH_PORT}"
echo "user            - ${NEW_USER}"
echo "password user   - ${USER_PASS}"
echo "password root   - ${ROOT_PASS}"
echo ""
echo "Подключение к серверу:"
echo "  ssh ${NEW_USER}@${SERVER_IP} -p ${SSH_PORT}"
echo ""
echo "──────────────── Hysteria2 ─────────────────────"
echo ""
echo "VPN user        - ${VPN_USER}"
echo "VPN password    - ${VPN_PASS}"
echo "Domain          - ${DOMAIN}"
echo ""
echo "Ваш конфиг Hysteria2:"
echo "${HY2_CONFIG}"
echo ""
echo "────────────────────────────────────────────────"
echo ""
echo "Клиенты:"
echo "  iOS:     Clash Mi (AppStore)"
echo "  Android: FLClashX или Clash Meta for Android"
echo "  Windows: Koala Clash (GitHub)"
echo ""
echo "Добавьте конфиг в приложение через 'Вставить из буфера обмена'"
echo "Проверьте IP на whoer.net или 2ip.ru"
echo ""
warn "Если Let's Encrypt не выпустил сертификат сразу — подождите 1-2 минуты и проверьте:"
warn "  systemctl status hysteria-server.service"
warn "  journalctl -u hysteria-server.service -n 50"
echo ""
