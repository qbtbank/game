#!/usr/bin/env bash
set -Eeuo pipefail

############################
# aaPanel Full One-Click Bootstrap
############################

# ===== CONFIG =====
PANEL_USER="${PANEL_USER:-administrator}"
PANEL_PASS="${PANEL_PASS:-ChangeMe_123!}"
PANEL_PORT="${PANEL_PORT:-17887}"
SSH_PORT="${SSH_PORT:-22}"

PROJECT_NAME="${PROJECT_NAME:-casino}"
APP_ARCHIVE="${APP_ARCHIVE:-/root/Casino.tar.gz}"
APP_ROOT="${APP_ROOT:-/www/wwwroot}"
APP_DIR="${APP_DIR:-/www/wwwroot/casino}"

DB_NAME="${DB_NAME:-cgame}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-Noname@2022}"
SQL_FILE="${SQL_FILE:-/root/cgame.sql}"

REDIS_PASS="${REDIS_PASS:-12345678a}"

PMA_VERSION="${PMA_VERSION:-5.2.1}"
PMA_DIR="${PMA_DIR:-/www/wwwroot/phpmyadmin}"

ENABLE_SWAP="${ENABLE_SWAP:-yes}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"

INSTALL_NVM_NODE="${INSTALL_NVM_NODE:-yes}"
NODE_VERSION="${NODE_VERSION:-20}"
NVM_VERSION="${NVM_VERSION:-v0.39.7}"

AAPANEL_INSTALL_URL="https://www.aapanel.com/script/install_7.0_en.sh"

# ===== LOG =====
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

cleanup() {
  rm -f /tmp/install_7.0_en.sh /tmp/phpmyadmin.zip >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Hay chay bang root: sudo bash $0"
    exit 1
  fi
}

check_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"
  fi
}

check_clean_env() {
  local found=0

  if command -v nginx >/dev/null 2>&1; then warn "Da co nginx."; found=1; fi
  if command -v apache2 >/dev/null 2>&1; then warn "Da co apache2."; found=1; fi
  if command -v httpd >/dev/null 2>&1; then warn "Da co httpd."; found=1; fi
  if command -v mysql >/dev/null 2>&1; then warn "Da co mysql."; found=1; fi
  if command -v php >/dev/null 2>&1; then warn "Da co php."; found=1; fi

  if [ "$found" -eq 1 ]; then
    err "aaPanel khuyen nghi he thong sach, chua co san Nginx/Apache/PHP/MySQL."
    err "Hay dung VPS moi de tranh xung dot."
    exit 1
  fi
}

check_input_files() {
  [ -f "${APP_ARCHIVE}" ] || { err "Khong tim thay file app: ${APP_ARCHIVE}"; exit 1; }
  [ -f "${SQL_FILE}" ] || warn "Khong tim thay file SQL: ${SQL_FILE}. Se bo qua import DB."
}

apt_prepare() {
  export DEBIAN_FRONTEND=noninteractive
  log "Cap nhat he thong va cai package co ban..."
  apt-get update -y
  apt-get install -y \
    curl wget ca-certificates unzip tar jq gnupg lsb-release \
    software-properties-common python3-pip ufw fail2ban socat net-tools
  pip3 install --upgrade pip
  pip3 install gdown
}

set_timezone() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Ho_Chi_Minh || true
  fi
}

setup_swap() {
  [ "${ENABLE_SWAP}" = "yes" ] || return 0

  local mem_mb swap_mb
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  swap_mb="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"

  if [ "$mem_mb" -lt 2048 ] && [ "$swap_mb" -eq 0 ]; then
    log "Tao swap ${SWAP_SIZE_MB}MB..."
    fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    log "Bo qua tao swap."
  fi
}

sysctl_tuning() {
  log "Ap dung tuning co ban..."
  cat >/etc/sysctl.d/99-aapanel-tuning.conf <<'EOF'
fs.file-max = 1000000
net.core.somaxconn = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 10240 65535
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl --system >/dev/null 2>&1 || true
}

setup_fail2ban() {
  log "Bat Fail2ban..."
  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
}

setup_firewall() {
  log "Cau hinh UFW..."
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "${SSH_PORT}"/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow "${PANEL_PORT}"/tcp
  ufw allow 6379/tcp || true

  ufw --force enable
}

prepare_dirs() {
  log "Tao thu muc..."
  mkdir -p "${APP_ROOT}"
  mkdir -p "${APP_DIR}"
  mkdir -p /www/wwwroot
}

install_aapanel() {
  log "Cai aaPanel..."
  curl -fsSL "${AAPANEL_INSTALL_URL}" -o /tmp/install_7.0_en.sh
  bash /tmp/install_7.0_en.sh
}

wait_bt() {
  log "Cho bt san sang..."
  for _ in $(seq 1 60); do
    if command -v bt >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  err "Khong tim thay lenh bt sau khi cai aaPanel."
  exit 1
}

configure_panel() {
  log "Dat password panel..."
  printf '%s\n' "${PANEL_PASS}" | bt 5 >/dev/null 2>&1 || warn "Khong dat duoc panel password."

  log "Dat username panel..."
  printf '%s\n' "${PANEL_USER}" | bt 6 >/dev/null 2>&1 || warn "Khong dat duoc panel username."

  log "Dat port panel..."
  printf '%s\n' "${PANEL_PORT}" | bt 8 >/dev/null 2>&1 || warn "Khong dat duoc panel port."
}

install_nvm_node() {
  [ "${INSTALL_NVM_NODE}" = "yes" ] || return 0

  log "Cai NVM + Node.js ${NODE_VERSION}..."
  export HOME="/root"
  export NVM_DIR="${HOME}/.nvm"

  if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  fi

  # shellcheck disable=SC1090
  source "${NVM_DIR}/nvm.sh"
  nvm install "${NODE_VERSION}"
  nvm alias default "${NODE_VERSION}"
  nvm use "${NODE_VERSION}"

  node -v
  npm -v
}

extract_app() {
  log "Giai nen source app tu ${APP_ARCHIVE} vao ${APP_DIR}..."

  rm -rf "${APP_DIR}"
  mkdir -p "${APP_DIR}"

  case "${APP_ARCHIVE}" in
    *.tar.gz|*.tgz)
      tar -xzf "${APP_ARCHIVE}" -C "${APP_DIR}" --strip-components=1 || tar -xzf "${APP_ARCHIVE}" -C "${APP_DIR}"
      ;;
    *.tar)
      tar -xf "${APP_ARCHIVE}" -C "${APP_DIR}" --strip-components=1 || tar -xf "${APP_ARCHIVE}" -C "${APP_DIR}"
      ;;
    *.zip)
      unzip -o "${APP_ARCHIVE}" -d "${APP_DIR}"
      ;;
    *)
      err "Dinh dang archive khong ho tro: ${APP_ARCHIVE}"
      exit 1
      ;;
  esac

  chown -R www:www "${APP_DIR}" 2>/dev/null || chown -R www-data:www-data "${APP_DIR}" 2>/dev/null || true
  chmod -R 755 "${APP_DIR}" || true
}

install_node_deps_if_package_json_exists() {
  if [ -f "${APP_DIR}/package.json" ]; then
    log "Phat hien package.json, dang cai dependency Node..."
    export HOME="/root"
    export NVM_DIR="${HOME}/.nvm"
    # shellcheck disable=SC1090
    source "${NVM_DIR}/nvm.sh"
    cd "${APP_DIR}"
    npm install
  else
    warn "Khong tim thay package.json trong ${APP_DIR}. Bo qua npm install."
  fi
}

mysql_setup_if_present() {
  local MYSQL_BIN=""

  if [ -x /www/server/mysql/bin/mysql ]; then
    MYSQL_BIN="/www/server/mysql/bin/mysql"
  elif command -v mysql >/dev/null 2>&1; then
    MYSQL_BIN="$(command -v mysql)"
  else
    warn "Chua tim thay MySQL cua aaPanel. Bo qua mysql bootstrap."
    return 0
  fi

  log "Cau hinh MySQL..."
  if "${MYSQL_BIN}" -uroot -e "SELECT VERSION();" >/dev/null 2>&1; then
    "${MYSQL_BIN}" -uroot <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
  else
    warn "Khong the dang nhap MySQL bang root khong mat khau. Bo qua ALTER USER."
  fi

  if [ -f "${SQL_FILE}" ]; then
    log "Import SQL vao ${DB_NAME}..."
    "${MYSQL_BIN}" -uroot -p"${MYSQL_ROOT_PASS}" "${DB_NAME}" < "${SQL_FILE}" || warn "Import SQL that bai."
  else
    warn "Khong co file SQL: ${SQL_FILE}"
  fi
}

redis_setup_if_present() {
  local REDIS_CONF="/www/server/redis/redis.conf"

  if [ ! -f "${REDIS_CONF}" ]; then
    warn "Chua tim thay Redis cua aaPanel. Bo qua redis bootstrap."
    return 0
  fi

  log "Cau hinh Redis..."
  sed -i 's/^supervised .*/supervised systemd/' "${REDIS_CONF}" || true
  sed -i 's/^bind .*/bind 0.0.0.0/' "${REDIS_CONF}" || true

  if grep -q '^#\?requirepass ' "${REDIS_CONF}"; then
    sed -i "s/^#\?requirepass .*/requirepass ${REDIS_PASS}/" "${REDIS_CONF}"
  else
    echo "requirepass ${REDIS_PASS}" >> "${REDIS_CONF}"
  fi

  mkdir -p /var/run/redis
  chown redis:redis /var/run/redis || true

  if [ -x /etc/init.d/redis ]; then
    /etc/init.d/redis restart || true
  else
    systemctl restart redis || true
  fi
}

prepare_phpmyadmin() {
  log "Chuan bi phpMyAdmin source..."
  local ZIP="phpMyAdmin-${PMA_VERSION}-all-languages.zip"
  local SRC_DIR="phpMyAdmin-${PMA_VERSION}-all-languages"

  cd /tmp
  curl -fL "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/${ZIP}" -o /tmp/phpmyadmin.zip
  unzip -o /tmp/phpmyadmin.zip >/dev/null

  rm -rf "${PMA_DIR}"
  mv "${SRC_DIR}" "${PMA_DIR}"

  chown -R www:www "${PMA_DIR}" 2>/dev/null || chown -R www-data:www-data "${PMA_DIR}" 2>/dev/null || true
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4 -sS --connect-timeout 5 https://api.ipify.org || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4 -sS --connect-timeout 5 https://ifconfig.me || true)"
  fi
  echo "${ip}"
}

summary() {
  local ip
  ip="$(detect_public_ip)"

  clear || true
  echo "================================================================"
  echo "aaPanel FULL ONE-CLICK BOOTSTRAP HOAN TAT"
  echo "================================================================"
  echo "Panel URL      : http://${ip:-YOUR_SERVER_IP}:${PANEL_PORT}"
  echo "Panel User     : ${PANEL_USER}"
  echo "Panel Password : ${PANEL_PASS}"
  echo "SSH Port       : ${SSH_PORT}"
  echo "Project Name   : ${PROJECT_NAME}"
  echo "App Archive    : ${APP_ARCHIVE}"
  echo "App Dir        : ${APP_DIR}"
  echo "SQL File       : ${SQL_FILE}"
  echo "Node Version   : ${NODE_VERSION}"
  echo "MySQL DB       : ${DB_NAME}"
  echo "MySQL Root Pass: ${MYSQL_ROOT_PASS}"
  echo "Redis Password : ${REDIS_PASS}"
  echo "phpMyAdmin Dir : ${PMA_DIR}"
  echo "================================================================"
  echo "SAU KHI DANG NHAP AAPANEL:"
  echo "1) Vao App Store cai: Nginx, MySQL, PHP, Redis"
  echo "2) Tao website tro vao: ${APP_DIR}"
  echo "3) Neu la Node app, vao Website -> Node Project hoac tu tao systemd service"
  echo "4) Neu MySQL/Redis chua co luc script chay, cai xong roi chay lai script"
  echo "================================================================"
}

main() {
  require_root
  check_os
  check_clean_env
  check_input_files
  apt_prepare
  set_timezone
  setup_swap
  sysctl_tuning
  setup_fail2ban
  setup_firewall
  prepare_dirs
  install_aapanel
  wait_bt
  configure_panel
  install_nvm_node
  extract_app
  install_node_deps_if_package_json_exists
  mysql_setup_if_present
  redis_setup_if_present
  prepare_phpmyadmin
  summary
}

main "$@"
