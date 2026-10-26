#!/usr/bin/env bash
# Tenangin - installer / updater satu perintah untuk VPS Ubuntu 22.04 / 24.04.
# Aman dijalankan berulang kali (idempotent): dipakai untuk install pertama maupun update.
#
#   sudo DOMAIN=tenangin.contoh.com EMAIL=anda@contoh.com \
#        OPENAI_API_KEY=sk-... DEEPGRAM_API_KEY=... bash deploy/install.sh
#
# Semua variabel opsional. Tanpa DOMAIN -> situs diakses lewat IP server (HTTP saja).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Jalankan dengan sudo/root."; exit 1; }

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$APP_DIR/apps/core"
API="$APP_DIR/apps/api-ai"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
DB_NAME="tenangin-app"
DB_USER="tenangin"
STATE="/root/.tenangin"
mkdir -p "$STATE"
export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

SERVER_IP="$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')"
HOST="${DOMAIN:-$SERVER_IP}"
SCHEME="http"; WS_SCHEME="ws"
if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then SCHEME="https"; WS_SCHEME="wss"; fi

# ---------------------------------------------------------------- paket sistem
log "Memasang paket sistem (nginx, MariaDB, PHP 8.3, Python, Node 20)"
apt-get update -y
apt-get install -y software-properties-common curl git unzip ca-certificates gnupg nginx mariadb-server \
    python3 python3-venv python3-pip ufw
if ! apt-cache show php8.3-fpm >/dev/null 2>&1; then
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
fi
apt-get install -y php8.3-fpm php8.3-cli php8.3-mysql php8.3-mbstring php8.3-xml php8.3-curl \
    php8.3-zip php8.3-bcmath php8.3-intl php8.3-gd

if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
if ! command -v composer >/dev/null; then
    curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi
systemctl enable --now mariadb php8.3-fpm nginx

# ---------------------------------------------------------------- database
log "Menyiapkan database"
if [ ! -f "$STATE/db_pass" ]; then
    openssl rand -hex 16 > "$STATE/db_pass"
    chmod 600 "$STATE/db_pass"
fi
DB_PASS="$(cat "$STATE/db_pass")"
mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

# ---------------------------------------------------------------- Laravel
log "Menyiapkan Laravel"
cd "$CORE"
set_env() { # set_env FILE KEY VALUE
    if grep -q "^$2=" "$1"; then sed -i "s|^$2=.*|$2=$3|" "$1"; else echo "$2=$3" >> "$1"; fi
}
[ -f .env ] || cp .env.example .env
set_env .env APP_ENV production
set_env .env APP_DEBUG false
set_env .env APP_URL "$SCHEME://$HOST"
set_env .env DB_CONNECTION mysql
set_env .env DB_HOST 127.0.0.1
set_env .env DB_PORT 3306
set_env .env DB_DATABASE "$DB_NAME"
set_env .env DB_USERNAME "$DB_USER"
set_env .env DB_PASSWORD "$DB_PASS"
set_env .env PY_AI_URL "http://127.0.0.1:5000"
set_env .env PY_AI_WS_URL "$WS_SCHEME://$HOST"
if ! grep -q "^PY_AI_TOKEN=" .env; then set_env .env PY_AI_TOKEN "$(openssl rand -hex 24)"; fi

composer install --no-dev --optimize-autoloader --no-interaction --no-scripts
grep -q "^APP_KEY=base64" .env || php artisan key:generate --force
php artisan package:discover --ansi || true
npm ci --no-audit --no-fund
npm run build
php artisan storage:link 2>/dev/null || true
php artisan migrate --force
if [ ! -f "$STATE/seeded" ]; then
    php artisan db:seed --force
    touch "$STATE/seeded"
fi
php artisan config:cache
php artisan route:cache
php artisan view:cache

# ---------------------------------------------------------------- FastAPI
log "Menyiapkan FastAPI (api-ai)"
cd "$API"
[ -d myenv ] || python3 -m venv myenv
./myenv/bin/pip install -q --upgrade pip
./myenv/bin/pip install -q -r requirements.txt
if [ ! -f .env ]; then
    cat > .env <<ENV
APP_ENV=prod
APP_PORT=5000
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASS
DB_DATABASE=$DB_NAME
OPENAI_API_KEY=sk-ISI-API-KEY-ANDA
OPENAI_MODEL=gpt-4o-mini
testing_deepgram_tenangin=
DEEPGRAM_MODEL=nova-2
ENV
fi
set_env .env DB_USERNAME "$DB_USER"
set_env .env DB_PASSWORD "$DB_PASS"
if [ -n "${OPENAI_API_KEY:-}" ]; then set_env .env OPENAI_API_KEY "$OPENAI_API_KEY"; fi
if [ -n "${DEEPGRAM_API_KEY:-}" ]; then set_env .env testing_deepgram_tenangin "$DEEPGRAM_API_KEY"; fi

# ---------------------------------------------------------------- izin file
chown -R www-data:www-data "$APP_DIR"
chmod -R ug+rwX "$CORE/storage" "$CORE/bootstrap/cache"

# ---------------------------------------------------------------- systemd
log "Membuat service systemd"
cat > /etc/systemd/system/tenangin-api.service <<UNIT
[Unit]
Description=Tenangin FastAPI
After=network.target mariadb.service

[Service]
User=www-data
WorkingDirectory=$API
ExecStart=$API/myenv/bin/uvicorn main:app --host 127.0.0.1 --port 5000
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/tenangin-queue.service <<UNIT
[Unit]
Description=Tenangin Laravel Queue
After=network.target mariadb.service

[Service]
User=www-data
WorkingDirectory=$CORE
ExecStart=/usr/bin/php artisan queue:work --sleep=3 --tries=3 --max-time=3600
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable tenangin-api tenangin-queue
systemctl restart tenangin-api tenangin-queue

# ---------------------------------------------------------------- nginx
log "Mengatur nginx"
cat > /etc/nginx/sites-available/tenangin <<NGINX
server {
    listen 80 default_server;
    server_name ${DOMAIN:-_};
    root $CORE/public;
    index index.php;
    client_max_body_size 50M;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    # WebSocket speech-to-text -> FastAPI
    location /ws/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }

    location ~ /\.(?!well-known) { deny all; }
}
NGINX
ln -sf /etc/nginx/sites-available/tenangin /etc/nginx/sites-enabled/tenangin
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null

if [ "$SCHEME" = "https" ]; then
    log "Memasang SSL (Lets Encrypt)"
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --no-eff-email --redirect -n
fi

systemctl restart php8.3-fpm
log "SELESAI -> $SCHEME://$HOST"
echo "Login awal: admin@gmail.com / admin  (SEGERA ganti password!)"
if grep -q "ISI-API-KEY" "$API/.env"; then
    echo "PERHATIAN: isi OPENAI_API_KEY di $API/.env lalu jalankan: systemctl restart tenangin-api"
fi
