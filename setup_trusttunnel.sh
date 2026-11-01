#!/bin/bash
# =============================================================================
# setup_trusttunnel.sh — Настройка VPS + установка TrustTunnel (AdGuard)
# =============================================================================
# Использование (чистый сервер — полная настройка, как в остальных скриптах):
#   bash setup_trusttunnel.sh \
#     --domain      ваш_домен           (например: tt.mooo.com) \
#     --user        имя_системного_пользователя \
#     --user-pass   пароль_юзера \
#     --root-pass   пароль_рута         (если не задан — генерируется автоматически) \
#     --ssh-port    порт_ssh            (из диапазона 1024-65535) \
#     --port        порт_trusttunnel    (по умолчанию: 443) \
#     --clients     кол-во_учёток       (по умолчанию: 10) \
#     --sni         доп_SNI             (необязательно, например: time.android.com) \
#     --email       ваш@email.com       (необязательно, для Let's Encrypt)
#
# Использование (сервер уже настроен — Hysteria2 или autoXRAY):
#   bash setup_trusttunnel.sh --addon --domain ваш_домен [--port 8443] [--clients 10]
#
#   В режиме --addon пароли, SSH и UFW не трогаются: ставится только TrustTunnel
#   и открывается его порт. Порт по умолчанию — 8443 (443 занят Hysteria/Xray).
#
# Скрипт должен запускаться от root на Debian 12 / Ubuntu 24
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
NEW_USER=""
USER_PASS=""
ROOT_PASS=""
SSH_PORT=""
TT_PORT=""
CLIENTS=10
EXTRA_SNI=""
EMAIL=""
ADDON=false

TT_DIR="/opt/trusttunnel"
TT_INSTALL_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh"
RESULT_FILE="/root/trusttunnel_clients.txt"

# ─── Парсинг аргументов ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    DOMAIN="$2";    shift 2 ;;
    --user)      NEW_USER="$2";  shift 2 ;;
    --user-pass) USER_PASS="$2"; shift 2 ;;
    --root-pass) ROOT_PASS="$2"; shift 2 ;;
    --ssh-port)  SSH_PORT="$2";  shift 2 ;;
    --port)      TT_PORT="$2";   shift 2 ;;
    --clients)   CLIENTS="$2";   shift 2 ;;
    --sni)       EXTRA_SNI="$2"; shift 2 ;;
    --email)     EMAIL="$2";     shift 2 ;;
    --addon)     ADDON=true;     shift ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ─── Проверка аргументов ─────────────────────────────────────────────────────
[[ -z "$DOMAIN" ]] && die "Укажите --domain"

if [[ "$ADDON" == false ]]; then
  [[ -z "$NEW_USER"  ]] && die "Укажите --user"
  [[ -z "$USER_PASS" ]] && die "Укажите --user-pass"
  [[ -z "$SSH_PORT"  ]] && die "Укажите --ssh-port"
  if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
    die "Порт SSH должен быть числом от 1024 до 65535"
  fi
fi

if [[ -z "$TT_PORT" ]]; then
  [[ "$ADDON" == true ]] && TT_PORT=8443 || TT_PORT=443
fi
if ! [[ "$TT_PORT" =~ ^[0-9]+$ ]] || (( TT_PORT < 1 || TT_PORT > 65535 )); then
  die "Порт TrustTunnel должен быть числом от 1 до 65535"
fi
[[ "$TT_PORT" == "80" ]] && die "Порт 80 нужен для выпуска сертификата, выберите другой"
[[ -n "$SSH_PORT" && "$TT_PORT" == "$SSH_PORT" ]] && die "Порт TrustTunnel совпадает с портом SSH"

if ! [[ "$CLIENTS" =~ ^[0-9]+$ ]] || (( CLIENTS < 1 || CLIENTS > 100 )); then
  die "--clients должен быть числом от 1 до 100"
fi

# Генерация пароля root если не задан (только в полном режиме)
if [[ "$ADDON" == false && -z "$ROOT_PASS" ]]; then
  ROOT_PASS=$(openssl rand -base64 18 | tr -d '/+=')
  warn "Пароль root не задан, сгенерирован автоматически: $ROOT_PASS"
fi

# Проверка что запущен от root
[[ $EUID -ne 0 ]] && die "Скрипт должен запускаться от root"

# ─── Получение IPv4 адреса сервера ───────────────────────────────────────────
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 api.ipify.org || ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
[[ -z "$SERVER_IP" ]] && die "Не удалось определить IP сервера"

# ─── Проверка что порт свободен ──────────────────────────────────────────────
# Занятость самим TrustTunnel (повторный запуск) не считается
PORT_BUSY=$(ss -H -lntup "sport = :${TT_PORT}" 2>/dev/null | grep -v trusttunnel || true)
if [[ -n "$PORT_BUSY" ]]; then
  echo "$PORT_BUSY"
  die "Порт ${TT_PORT} уже занят (см. выше). Укажите другой через --port"
fi

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
if [[ "$ADDON" == true ]]; then
  echo -e "${BOLD}   TrustTunnel (addon) на порт ${TT_PORT}${NC}"
else
  echo -e "${BOLD}   Настройка VPS + TrustTunnel                      ${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

export DEBIAN_FRONTEND=noninteractive

if [[ "$ADDON" == false ]]; then
  # ─── 1. Смена пароля root ───────────────────────────────────────────────────
  info "Шаг 1/7: Смена пароля root..."
  echo "root:${ROOT_PASS}" | chpasswd
  log "Пароль root изменён"

  # ─── 2. Обновление пакетов ─────────────────────────────────────────────────
  info "Шаг 2/7: Обновление пакетов (может занять 5-10 минут)..."
  apt-get update -y -q
  apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
  log "Пакеты обновлены"

  # ─── 3. Создание нового пользователя ───────────────────────────────────────
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

  # ─── 4. Настройка SSH ──────────────────────────────────────────────────────
  info "Шаг 4/7: Настройка SSH (порт ${SSH_PORT}, запрет входа root)..."
  SSHD_CONFIG="/etc/ssh/sshd_config"
  cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

  sed -i "s/^#*Port .*/Port ${SSH_PORT}/" "$SSHD_CONFIG"
  grep -q "^Port " "$SSHD_CONFIG" || echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"

  sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
  grep -q "^PermitRootLogin " "$SSHD_CONFIG" || echo "PermitRootLogin no" >> "$SSHD_CONFIG"

  systemctl restart sshd
  log "SSH перенастроен: порт ${SSH_PORT}, вход root запрещён"

  # ─── 5. Установка Fail2ban ─────────────────────────────────────────────────
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
else
  apt-get update -y -q
fi

# ─── 6. Установка TrustTunnel ────────────────────────────────────────────────
info "Шаг 6/7: Установка TrustTunnel и сертификата..."
apt-get install -y -q curl openssl certbot dnsutils

# Проверка привязки домена — без неё сертификат не выпустится
info "Проверка привязки домена ${DOMAIN} к IP ${SERVER_IP}..."
DOMAIN_IP=$(dig +short -t A "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1 || true)
if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
  die "Домен ${DOMAIN} указывает на ${DOMAIN_IP:-не определён}, а не на ${SERVER_IP}. Исправьте A-запись и запустите скрипт снова."
fi
log "Домен указывает на этот сервер"

# Остановка при повторном запуске
systemctl stop trusttunnel 2>/dev/null || true

curl -fsSL "$TT_INSTALL_URL" | sh -s -
[[ -x "${TT_DIR}/trusttunnel_endpoint" ]] || die "TrustTunnel не установился в ${TT_DIR}"
log "TrustTunnel установлен в ${TT_DIR}"

# Выпуск сертификата. Способ зависит от того, кто держит 80-й порт:
#   никто            → certbot standalone
#   nginx (autoXRAY) → webroot /var/www/html, nginx уже отдаёт оттуда acme-challenge
#   hysteria         → standalone, Hysteria останавливается на время выпуска/продления
CERTBOT_ARGS=(certonly --non-interactive --agree-tos --keep-until-expiring
              --cert-name "$DOMAIN" -d "$DOMAIN"
              --deploy-hook "systemctl restart trusttunnel")
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

PORT80=$(ss -H -lntp "sport = :80" 2>/dev/null || true)
if [[ -z "$PORT80" ]]; then
  info "Порт 80 свободен — certbot standalone"
  CERTBOT_ARGS+=(--standalone)
elif echo "$PORT80" | grep -q '"nginx"' && [[ -d /var/www/html ]]; then
  info "Порт 80 занят nginx — certbot webroot (/var/www/html)"
  CERTBOT_ARGS+=(--webroot -w /var/www/html)
elif echo "$PORT80" | grep -q '"hysteria"'; then
  info "Порт 80 занят Hysteria — certbot standalone с её остановкой на время выпуска"
  CERTBOT_ARGS+=(--standalone
                 --pre-hook "systemctl stop hysteria-server"
                 --post-hook "systemctl start hysteria-server")
else
  echo "$PORT80"
  die "Порт 80 занят неизвестным процессом (см. выше), не могу выпустить сертификат"
fi

certbot "${CERTBOT_ARGS[@]}" || die "certbot не смог выпустить сертификат для ${DOMAIN}"
CERT_CHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
[[ -f "$CERT_CHAIN" && -f "$CERT_KEY" ]] || die "Файлы сертификата не найдены в /etc/letsencrypt/live/${DOMAIN}"
log "Сертификат выпущен, автопродление через certbot.timer (с перезапуском trusttunnel)"

# Генерация конфигов через официальный setup_wizard
info "Генерация конфигурации TrustTunnel..."
cd "$TT_DIR"
for f in vpn.toml hosts.toml credentials.toml rules.toml; do
  [[ -f "$f" ]] && mv -f "$f" "${f}.bak"
done

gen_pass() { openssl rand -hex 8; }

FIRST_PASS=$(gen_pass)
./setup_wizard -m non-interactive \
  -a "0.0.0.0:${TT_PORT}" \
  -c "user1:${FIRST_PASS}" \
  -n "$DOMAIN" \
  --lib-settings vpn.toml \
  --hosts-settings hosts.toml \
  --cert-type provided \
  --cert-chain-path "$CERT_CHAIN" \
  --cert-key-path "$CERT_KEY" </dev/null \
  || die "setup_wizard завершился с ошибкой"
[[ -f vpn.toml && -f hosts.toml ]] || die "setup_wizard не создал vpn.toml / hosts.toml"

# Сертификат — напрямую из letsencrypt, чтобы продление подхватывалось само
sed -i -E "s|^[[:space:]]*cert_chain_path[[:space:]]*=.*|cert_chain_path = \"${CERT_CHAIN}\"|"  hosts.toml
sed -i -E "s|^[[:space:]]*private_key_path[[:space:]]*=.*|private_key_path = \"${CERT_KEY}\"|" hosts.toml
grep -qF "$CERT_CHAIN" hosts.toml || die "Не удалось прописать путь к сертификату в hosts.toml"

# Дополнительный SNI (например time.android.com)
if [[ -n "$EXTRA_SNI" ]]; then
  sed -i -E '/^[[:space:]]*allowed_sni[[:space:]]*=/d' hosts.toml
  sed -i "/^private_key_path = /a allowed_sni = [\"${EXTRA_SNI}\"]" hosts.toml
fi

# Учётки: user1..userN
CREDS_FILE=$(grep -oP '^credentials_file\s*=\s*"\K[^"]+' vpn.toml || echo "credentials.toml")
declare -a TT_USERS TT_PASSES
: > "$CREDS_FILE"
for (( i=1; i<=CLIENTS; i++ )); do
  TT_USERS[$i]="user${i}"
  if (( i == 1 )); then TT_PASSES[$i]="$FIRST_PASS"; else TT_PASSES[$i]=$(gen_pass); fi
  printf '[[client]]\nusername = "%s"\npassword = "%s"\n\n' "${TT_USERS[$i]}" "${TT_PASSES[$i]}" >> "$CREDS_FILE"
done
chmod 600 "$CREDS_FILE"
log "Создано учёток: ${CLIENTS}"

# Служба systemd
cp trusttunnel.service.template /etc/systemd/system/trusttunnel.service
systemctl daemon-reload
systemctl enable trusttunnel
systemctl restart trusttunnel
sleep 3
systemctl is-active --quiet trusttunnel || { journalctl -u trusttunnel -n 30 --no-pager; die "trusttunnel не запустился (лог выше)"; }
log "TrustTunnel запущен и добавлен в автозагрузку"

# ─── 7. Firewall ─────────────────────────────────────────────────────────────
info "Шаг 7/7: Настройка UFW Firewall..."
if [[ "$ADDON" == false ]]; then
  apt-get install -y -q ufw
  ufw --force reset

  ufw allow OpenSSH
  ufw allow "${SSH_PORT}/tcp"
  ufw allow 80/tcp
  ufw allow "${TT_PORT}/tcp"
  ufw allow "${TT_PORT}/udp"

  ufw --force enable
  log "UFW настроен и включён"
elif command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "${TT_PORT}/tcp"
  ufw allow "${TT_PORT}/udp"
  log "В UFW открыт порт ${TT_PORT} (tcp/udp)"
else
  warn "UFW не активен — правила не добавлены"
fi

# ─── Проверка прослушивания ──────────────────────────────────────────────────
LISTEN_TCP=$(ss -H -lnt "sport = :${TT_PORT}" | wc -l)
LISTEN_UDP=$(ss -H -lnu "sport = :${TT_PORT}" | wc -l)
(( LISTEN_TCP > 0 )) && log "Порт ${TT_PORT}/tcp слушается (HTTP/1.1, HTTP/2)" || warn "Порт ${TT_PORT}/tcp НЕ слушается"
(( LISTEN_UDP > 0 )) && log "Порт ${TT_PORT}/udp слушается (QUIC)"            || warn "Порт ${TT_PORT}/udp НЕ слушается"

# ─── Экспорт deeplink-ссылок ─────────────────────────────────────────────────
declare -a TT_LINKS
for (( i=1; i<=CLIENTS; i++ )); do
  TT_LINKS[$i]=$(./trusttunnel_endpoint vpn.toml hosts.toml \
                   -c "${TT_USERS[$i]}" -a "${DOMAIN}:${TT_PORT}" \
                   --name "TT-${DOMAIN}-${TT_USERS[$i]}" 2>/dev/null \
                 | grep -oE 'tt://[^[:space:]]+' | head -1 || true)
done

# ─── Сохранение учёток ───────────────────────────────────────────────────────
{
  echo "TrustTunnel — ${DOMAIN}:${TT_PORT}"
  [[ -n "$EXTRA_SNI" ]] && echo "Доп. SNI: ${EXTRA_SNI}"
  echo ""
  for (( i=1; i<=CLIENTS; i++ )); do
    echo "HOST: ${DOMAIN}"
    echo "PORT: ${TT_PORT}"
    echo "LOGIN: ${TT_USERS[$i]}"
    echo "PASS: ${TT_PASSES[$i]}"
    [[ -n "${TT_LINKS[$i]}" ]] && echo "LINK: ${TT_LINKS[$i]}"
    echo "----------------------"
  done
} > "$RESULT_FILE"
chmod 600 "$RESULT_FILE"

# ─── Итоговый вывод ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         НАСТРОЙКА ЗАВЕРШЕНА — СОХРАНИТЕ ЭТО     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
if [[ "$ADDON" == false ]]; then
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
fi
echo "──────────────── TrustTunnel ───────────────────"
echo ""
cat "$RESULT_FILE"
echo ""
echo "Учётки сохранены в ${RESULT_FILE}"
echo ""
echo "Клиенты:"
echo "  iOS / macOS: TrustTunnel (App Store)"
echo "  Android:     TrustTunnel (Google Play)"
echo ""
echo "Ссылку tt:// можно просто открыть на телефоне. Вручную: Server — ${DOMAIN}:${TT_PORT},"
echo "логин/пароль из списка, протокол — HTTP/2."
if [[ -n "$EXTRA_SNI" ]]; then
  echo "Чтобы использовать доп. SNI, укажите в клиенте Custom SNI: ${EXTRA_SNI}"
fi
echo ""
