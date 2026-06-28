#!/bin/bash
# =============================================================================
# setup_ru_bridge.sh — Настройка российского VPS + создание моста к иностранному
# =============================================================================
# Использование:
#   bash setup_ru_bridge.sh \
#     --domain      ваш_новый_домен       (новый домен для RU сервера) \
#     --xhttp-config "vless://..."        (конфиг vless XHTTP reality EXTRA с иностранного сервера) \
#     --user        имя_пользователя \
#     --user-pass   пароль_юзера \
#     --root-pass   пароль_рута           (если не задан — генерируется автоматически) \
#     --ssh-port    порт_ssh              (из диапазона 10001-65535) \
#     --bridge-script URL_скрипта        (по умолчанию: autoXRAYselfRUbrEUxhttp.sh)
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
XHTTP_CONFIG=""
NEW_USER=""
USER_PASS=""
ROOT_PASS=""
SSH_PORT=""
BRIDGE_SCRIPT_URL="https://raw.githubusercontent.com/xVRVx/autoXRAY/main/autoXRAYselfRUbrEUxhttp.sh"

# ─── Парсинг аргументов ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)        DOMAIN="$2";            shift 2 ;;
    --xhttp-config)  XHTTP_CONFIG="$2";      shift 2 ;;
    --user)          NEW_USER="$2";           shift 2 ;;
    --user-pass)     USER_PASS="$2";          shift 2 ;;
    --root-pass)     ROOT_PASS="$2";          shift 2 ;;
    --ssh-port)      SSH_PORT="$2";           shift 2 ;;
    --bridge-script) BRIDGE_SCRIPT_URL="$2";  shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ─── Проверка обязательных аргументов ────────────────────────────────────────
[[ -z "$DOMAIN"       ]] && die "Укажите --domain (новый домен для RU сервера)"
[[ -z "$XHTTP_CONFIG" ]] && die "Укажите --xhttp-config (конфиг vless XHTTP с иностранного сервера)"
[[ -z "$NEW_USER"     ]] && die "Укажите --user"
[[ -z "$USER_PASS"    ]] && die "Укажите --user-pass"
[[ -z "$SSH_PORT"     ]] && die "Укажите --ssh-port"

# Проверка диапазона порта
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
  die "Порт SSH должен быть числом от 1024 до 65535"
fi

# Генерация пароля root если не задан
if [[ -z "$ROOT_PASS" ]]; then
  ROOT_PASS=$(tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 20)
  warn "Пароль root не задан, сгенерирован автоматически: $ROOT_PASS"
fi

# Проверка что запущен от root
[[ $EUID -ne 0 ]] && die "Скрипт должен запускаться от root (su - или sudo)"

# ─── Получение IP сервера ─────────────────────────────────────────────────────
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 api.ipify.org || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
[[ -z "$SERVER_IP" ]] && die "Не удалось определить IP сервера"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Настройка российского VPS (мост)                 ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

# ─── 1. Смена пароля root ─────────────────────────────────────────────────────
info "Шаг 1/6: Смена пароля root..."
echo "root:${ROOT_PASS}" | chpasswd
log "Пароль root изменён"

# ─── 2. Обновление пакетов ───────────────────────────────────────────────────
info "Шаг 2/6: Обновление пакетов (это может занять 5-10 минут)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
log "Пакеты обновлены"

# ─── 3. Создание нового пользователя ─────────────────────────────────────────
info "Шаг 3/6: Создание пользователя '${NEW_USER}'..."
if id "$NEW_USER" &>/dev/null; then
  warn "Пользователь '$NEW_USER' уже существует, обновляю пароль..."
  echo "${NEW_USER}:${USER_PASS}" | chpasswd
else
  adduser --gecos "" --disabled-password "$NEW_USER"
  echo "${NEW_USER}:${USER_PASS}" | chpasswd
fi
usermod -aG sudo "$NEW_USER"
log "Пользователь '${NEW_USER}' создан и добавлен в sudo"

# ─── 4. Смена порта SSH и запрет входа root ───────────────────────────────────
info "Шаг 4/6: Настройка SSH (порт ${SSH_PORT}, запрет входа root)..."
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

sed -i "s/^#*Port .*/Port ${SSH_PORT}/" "$SSHD_CONFIG"
grep -q "^Port " "$SSHD_CONFIG" || echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"

sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
grep -q "^PermitRootLogin " "$SSHD_CONFIG" || echo "PermitRootLogin no" >> "$SSHD_CONFIG"

systemctl restart sshd
log "SSH перенастроен: порт ${SSH_PORT}, вход root запрещён"

# ─── 5. Установка и настройка Fail2ban ───────────────────────────────────────
info "Шаг 5/6: Установка Fail2ban..."
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

# ─── 6. Настройка Firewall (UFW) ─────────────────────────────────────────────
info "Шаг 6/6: Настройка UFW Firewall..."
apt-get install -y -q ufw
ufw --force reset

ufw allow OpenSSH
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8442/tcp
ufw allow 8443/tcp
ufw allow 10443/tcp
ufw allow 8080/tcp
ufw allow 8080/udp

ufw --force enable
log "UFW настроен и включён"

# ─── Запуск скрипта моста ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Установка моста RU → Foreign                     ${NC}"
echo -e "${BOLD}   Домен: ${DOMAIN}${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

# Проверка доступности домена
info "Проверка привязки домена ${DOMAIN} к IP ${SERVER_IP}..."
DOMAIN_IP=$(dig +short -t A "$DOMAIN" 2>/dev/null | tail -1 || getent ahostsv4 "$DOMAIN" | awk '{print $1}' | head -1 || echo "")
if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
  warn "Домен ${DOMAIN} указывает на ${DOMAIN_IP}, а не на ${SERVER_IP}."
  warn "Убедитесь что домен привязан к этому серверу. Продолжаю через 10 секунд..."
  sleep 10
fi

# Запуск скрипта моста и захват вывода
VPN_OUTPUT_FILE=$(mktemp)
info "Запуск скрипта моста: ${BRIDGE_SCRIPT_URL}"
set +e  # отключаем остановку на ошибке
bash -c "$(curl -L "${BRIDGE_SCRIPT_URL}")" -- "${DOMAIN}" "${XHTTP_CONFIG}" 2>&1 | tee "$VPN_OUTPUT_FILE"
VPN_EXIT_CODE=${PIPESTATUS[0]}
set -e  # включаем обратно
VPN_OUTPUT=$(cat "$VPN_OUTPUT_FILE")
rm -f "$VPN_OUTPUT_FILE"
if [[ $VPN_EXIT_CODE -ne 0 ]]; then
  warn "Скрипт моста завершился с кодом ${VPN_EXIT_CODE} (это не всегда ошибка)"
else
  log "Скрипт моста выполнен успешно"
fi

# ─── Итоговый вывод ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    RU МОСТ НАСТРОЕН — СОХРАНИТЕ ЭТИ ДАННЫЕ      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Remote Server Settings (RU Bridge):"
echo "IP              - ${SERVER_IP}"
echo "SSH port        - ${SSH_PORT}"
echo "user            - ${NEW_USER}"
echo "password user   - ${USER_PASS}"
echo "password root   - ${ROOT_PASS}"
echo ""
echo "Подключение к серверу:"
echo "  ssh ${NEW_USER}@${SERVER_IP} -p ${SSH_PORT}"
echo ""
echo "─────────────── VPN конфиги (мост) ────────────────"
echo "${VPN_OUTPUT}"
echo "────────────────────────────────────────────────────"
echo ""
