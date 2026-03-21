#!/bin/bash
set -e

# =================================================================
# DIGITALOCEAN SGP1 UBUNTU 22.04 - AAPANEL + EXPRESS CASINO BACKEND
# 8GB/160GB + Node20.14 + Nginx/Redis/MySQL/PHP8.1 + PM2 + SSL
# Deploy: https://github.com/bitachaien/backend.git → /www/wwwroot/Casino/Casino/Server
# =================================================================

# Màu sắc log
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ========== 1. SYSTEM UPDATE ==========
log "🔄 Cập nhật system packages..."
apt update && apt upgrade -y && apt autoremove -y

# ========== 2. UFW FIREWALL (TRƯỚC AAPANEL) ==========
log "🛡️ Setup UFW..."
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw --force enable
ufw status

# ========== 3. AAPANEL ==========
log "🖥️ Cài aaPanel 7.8+ (Ubuntu 22.04 compatible)..."
wget -O install.sh http://www.aapanel.com/script/install_7.0_en.sh 
chmod +x install.sh
bash install.sh aapanel
rm install.sh
log "✅ aaPanel installed! Check console for username/password + port (8888/31902)"

# ========== 4. NODE.JS 20.14.0 ==========
log "🐳 Cài Node.js 20.14.0 + npm@latest..."
curl -fsSL https://nodejs.org/dist/v20.14.0/node-v20.14.0-linux-x64.tar.xz | tar -xJ -C /usr/local --strip-components=1
npm install -g npm@latest pm2@latest yarn@latest

# ========== 5. DIRECTORY STRUCTURE ==========
log "📁 Tạo /www/wwwroot/Casino/Casino/Server (www:www)..."
mkdir -p /www/wwwroot/Casino/Casino/Server
chown -R www:www /www/wwwroot/Casino
chmod -R 755 /www/wwwroot/Casino/Casino/Server

cd /www/wwwroot/Casino/Casino/Server

# ========== 6. CLONE + BACKEND SETUP ==========
log "📥 Clone https://github.com/bitachaien/backend.git..."
git clone https://github.com/bitachaien/backend.git .
rm -rf .git  # Clean theo yêu cầu

# Detect Express entry file
if [ -f "server.js" ]; then
  ENTRY="server.js"
elif [ -f "app.js" ]; then  
  ENTRY="app.js"
elif [ -f "index.js" ]; then
  ENTRY="index.js"
elif grep -q '"main"' package.json; then
  ENTRY=$(grep '"main"' package.json | sed -E 's/.*"main": "([^"]+)".*/\1/')
else
  error "❌ Không tìm thấy Express entry file!"
fi
log "🎯 Express entry: $ENTRY"

# Install deps as www user
su - www -c "cd /www/wwwroot/Casino/Casino/Server && npm install --production"

# ========== 7. .ENV CONFIG ==========
log "⚙️ Tạo .env (cgame/admin/Noname@2020 + Redis 12345678a)..."
cat > .env << 'EOF'
# Database
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=cgame
DB_USER=admin
DB_PASS=Noname@2020

# Redis
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASS=12345678a

# App
NODE_ENV=production
PORT=8009
EOF
chown www:www .env
chmod 600 .env

# ========== 8. PM2 ECOSYSTEM ==========
log "🚀 Tạo ecosystem.config.js..."
cat > ecosystem.config.js << EOF
module.exports = {
  apps: [{
    name: 'CasinoServer',
    script: './$ENTRY',
    cwd: '/www/wwwroot/Casino/Casino/Server',
    instances: 1,
    exec_mode: 'fork',
    autorestart: true,
    watch: false,
    max_memory_restart: '2G',
    env: {
      NODE_ENV: 'production',
      PORT: 8009
    },
    env_file: './.env',
    error_file: './logs/err.log',
    out_file: './logs/out.log',
    log_file: './logs/combined.log',
    time: true
  }]
};
EOF
chown www:www ecosystem.config.js
mkdir -p logs && chown www:www logs

# PM2 setup
su - www -c "pm2 start ecosystem.config.js --env production"
pm2 save
eval "$(pm2 startup systemd -u www --hp /home/www)"

# ========== 9. REDIS PASSWORD ==========
log "🔐 Setup Redis password 12345678a..."
if [ -f /www/server/redis/etc/redis.conf ]; then
  sed -i 's/^#* *requirepass .*/requirepass 12345678a/' /www/server/redis/etc/redis.conf
  systemctl restart redis-server || systemctl restart redis
  redis-cli -a 12345678a ping && log "✅ Redis OK"
fi

# ========== 10. MYSQL PREP ==========
log "🗄️ MySQL prep (full setup qua aaPanel DB Manager)..."
# aaPanel sẽ cài MySQL → tạo DB/user qua giao diện

# ========== 11. NGINX TEMPLATE ==========
log "🌐 Nginx reverse proxy template..."
cat > /tmp/casino-backend.conf << 'EOF'
# Copy vào aaPanel > Websites > Add Site > Nginx Config
server {
    listen 80;
    server_name api.yourdomain.com;  # ← THAY DOMAIN/IP
    index index.html index.htm;
    
    location / {
        proxy_pass http://127.0.0.1:8009;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
    
    # API docs nếu có
    location /swagger {
        proxy_pass http://127.0.0.1:8009;
    }
}
EOF
log "📋 Copy /tmp/casino-backend.conf vào aaPanel"

# ========== 12. FINAL CHECK ==========
log "${GREEN}🎉 SETUP HOÀN TẤT!${NC}"
log ""
log "📋 BƯỚC CUỐI QUA AAPANEL (http://IP:PORT):"
log "1. App Store → Cài: MySQL-8.0 | PHP-8.1 | phpMyAdmin | Redis Manager"
log "2. Database → Add: 'cgame' → User: admin (Noname@2020)"
log "3. Websites → Add Site → Domain: api.yourdomain.com"
log "   → Runtime: Node Project → Path: /www/wwwroot/Casino/Casino/Server"
log "   → Port: 8009 → SSL: Let's Encrypt"
log "4. Paste Nginx config từ /tmp/casino-backend.conf"
log ""
log "🔍 KIỂM TRA:"
log "   pm2 list | pm2 logs CasinoServer"
log "   curl http://localhost:8009"
log "   redis-cli -a 12345678a ping"
log "   mysql -u admin -pNoname@2020 -D cgame -e 'SHOW TABLES;'"
log ""
log "📊 PM2 Dashboard: pm2 monit"
log "🛡️ Logs: tail -f /www/wwwroot/Casino/Casino/Server/logs/*"
