#!/usr/bin/env bash
# Tenangin - installer / updater satu perintah untuk VPS Ubuntu 22.04 / 24.04 / 25.04.
# Aman dijalankan berulang kali (idempotent): dipakai untuk install pertama maupun update.
# Server yang sudah berisi (MySQL, PHP, .env, sertifikat SSL) dipakai ulang, bukan ditimpa.
#
#   sudo DOMAIN=tenangin.contoh.com EMAIL=anda@contoh.com \
#        OPENAI_API_KEY=sk-... DEEPGRAM_API_KEY=... bash deploy/install.sh
#
# Semua variabel opsional. Tanpa DOMAIN -> situs diakses lewat IP server (HTTP saja).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Jalankan dengan sudo/root."; exit 1; }

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CORE="$APP_DIR/apps/core"
API="$APP_DIR/apps/api-ai"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
DB_NAME="tenangin-app"
DB_USER="tenangin"
STATE="/root/.tenangin"
mkdir -p "$STATE"
export DEBIAN_FRONTEND=noninteractive
export COMPOSER_ALLOW_SUPERUSER=1

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }
env_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }
set_env() { # set_env FILE KEY VALUE
    if grep -q "^$2=" "$1"; then sed -i "s|^$2=.*|$2=$3|" "$1"; else echo "$2=$3" >> "$1"; fi
}

SERVER_IP="$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')"
HOST="${DOMAIN:-$SERVER_IP}"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
SCHEME="http"; WS_SCHEME="ws"
if [ -n "$DOMAIN" ] && { [ -f "$CERT_DIR/fullchain.pem" ] || [ -n "$EMAIL" ]; }; then
    SCHEME="https"; WS_SCHEME="wss"
fi

# ---------------------------------------------------------------- paket sistem
log "Memasang paket sistem"
apt-get update -y
apt-get install -y software-properties-common curl git unzip ca-certificates gnupg nginx \
    python3 python3-venv python3-pip python3-dev build-essential pkg-config ufw

# Pakai MySQL/MariaDB yang sudah ada; pasang MariaDB hanya jika belum ada server database.
if ! command -v mysql >/dev/null; then apt-get install -y mariadb-server; fi
DB_SVC="$(systemctl list-unit-files | grep -oE '^(mysql|mariadb)\.service' | head -1 | sed 's/\.service//')"

# Pakai PHP yang sudah ada; jika belum ada pasang 8.3.
if command -v php >/dev/null; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
else
    PHP_VER="8.3"
    if ! apt-cache show php8.3-fpm >/dev/null 2>&1; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update -y
    fi
fi
apt-get install -y php$PHP_VER-fpm php$PHP_VER-cli php$PHP_VER-mysql php$PHP_VER-mbstring php$PHP_VER-xml \
    php$PHP_VER-curl php$PHP_VER-zip php$PHP_VER-bcmath php$PHP_VER-intl php$PHP_VER-gd

if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
if ! command -v composer >/dev/null; then
    curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# Apache bawaan sering menduduki port 80 -> matikan agar nginx bisa jalan.
if systemctl is-active --quiet apache2; then systemctl disable --now apache2; fi
systemctl enable --now "$DB_SVC" "php$PHP_VER-fpm"

# ---------------------------------------------------------------- database
log "Menyiapkan database"
if [ -n "$(env_get "$CORE/.env" DB_PASSWORD)" ] && [ -n "$(env_get "$CORE/.env" DB_DATABASE)" ]; then
    # .env sudah berisi kredensial -> database lama dipertahankan apa adanya
    DB_NAME="$(env_get "$CORE/.env" DB_DATABASE)"
    DB_USER="$(env_get "$CORE/.env" DB_USERNAME)"
    DB_PASS="$(env_get "$CORE/.env" DB_PASSWORD)"
    echo "Memakai database yang sudah ada: $DB_NAME"
else
    if [ ! -f "$STATE/db_pass" ]; then
        openssl rand -hex 16 > "$STATE/db_pass"
        chmod 600 "$STATE/db_pass"
    fi
    DB_PASS="$(cat "$STATE/db_pass")"
fi
mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

# ---------------------------------------------------------------- Laravel
log "Menyiapkan Laravel"
cd "$CORE"
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
if [ -z "$(env_get .env PY_AI_TOKEN)" ]; then set_env .env PY_AI_TOKEN "$(openssl rand -hex 24)"; fi

composer install --no-dev --optimize-autoloader --no-interaction --no-scripts
rm -f bootstrap/cache/packages.php bootstrap/cache/services.php bootstrap/cache/config.php
grep -q "^APP_KEY=base64" .env || php artisan key:generate --force
php artisan package:discover --ansi || true
npm ci --no-audit --no-fund
npm run build
php artisan storage:link 2>/dev/null || true
php artisan migrate --force
# Seeder hanya dijalankan pada database yang masih kosong.
if [ "$(mysql -N -e "SELECT COUNT(*) FROM \`$DB_NAME\`.users")" = "0" ]; then
    php artisan db:seed --force
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
set_env .env DB_DATABASE "$DB_NAME"
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
After=network.target $DB_SVC.service

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
After=network.target $DB_SVC.service

[Service]
User=www-data
WorkingDirectory=$CORE
ExecStart=/usr/bin/php$PHP_VER artisan queue:work --sleep=3 --tries=3 --max-time=3600
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable tenangin-api tenangin-queue
systemctl restart tenangin-api tenangin-queue

# ---------------------------------------------------------------- nginx
log "Mengatur nginx"
STATUS_PHP="$APP_DIR/deploy/status/index.php"
LOCATIONS=$(cat <<LOC
    root $CORE/public;
    index index.php;
    client_max_body_size 50M;

    # Halaman status mandiri (tidak lewat Laravel) -> /_status
    location = /_status {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $STATUS_PHP;
        fastcgi_pass unix:/run/php/php$PHP_VER-fpm.sock;
    }

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php$PHP_VER-fpm.sock;
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
LOC
)
# Sembunyikan versi nginx & PHP dari header respons.
echo "server_tokens off;" > /etc/nginx/conf.d/tenangin-hardening.conf
echo "expose_php = Off" > "/etc/php/$PHP_VER/fpm/conf.d/99-tenangin.ini"
# Konfigurasi lama dengan server_name yang sama dipindah agar tidak bentrok.
mkdir -p "$STATE/old-nginx"
for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in tenangin|tenangin.conf|default) mv "$f" "$STATE/old-nginx/";; esac
done

if [ -f "$CERT_DIR/fullchain.pem" ]; then
    # Sertifikat SSL sudah ada -> langsung dipakai.
    cat > /etc/nginx/sites-available/tenangin <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    location /.well-known/acme-challenge/ { root $CORE/public; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN www.$DOMAIN;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
$LOCATIONS
}
NGINX
else
    cat > /etc/nginx/sites-available/tenangin <<NGINX
server {
    listen 80 default_server;
    server_name ${DOMAIN:-_};
$LOCATIONS
}
NGINX
fi
ln -sf /etc/nginx/sites-available/tenangin /etc/nginx/sites-enabled/tenangin
nginx -t
systemctl enable nginx
systemctl restart nginx

# ---------------------------------------------------------------- status.<domain>
# Aktif otomatis begitu A record status.<domain> mengarah ke server ini.
if [ -n "$DOMAIN" ] && [ -f "$STATUS_PHP" ]; then
    STATUS_HOST="status.$DOMAIN"
    STATUS_LOC="location / {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $STATUS_PHP;
        fastcgi_pass unix:/run/php/php$PHP_VER-fpm.sock;
    }"
    write_status_vhost() { # write_status_vhost <with_ssl: 0|1>
        {
            echo "server {
    listen 80;
    listen [::]:80;
    server_name $STATUS_HOST;
    location /.well-known/acme-challenge/ { root $CORE/public; }"
            if [ "$1" = "1" ]; then echo "    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $STATUS_HOST;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    $STATUS_LOC
}"; else echo "    $STATUS_LOC
}"; fi
        } > /etc/nginx/sites-available/tenangin-status
        ln -sf /etc/nginx/sites-available/tenangin-status /etc/nginx/sites-enabled/tenangin-status
        nginx -t && systemctl reload nginx
    }
    RESOLVED="$(getent ahostsv4 "$STATUS_HOST" | awk '{print $1; exit}' || true)"
    if [ -z "$RESOLVED" ] && command -v dig >/dev/null; then RESOLVED="$(dig +short "$STATUS_HOST" @1.1.1.1 | tail -1 || true)"; fi
    if [ "$RESOLVED" = "$SERVER_IP" ]; then
        log "Mengaktifkan https://$STATUS_HOST"
        write_status_vhost 0
        if [ -f "$CERT_DIR/fullchain.pem" ]; then
            if ! openssl x509 -noout -ext subjectAltName -in "$CERT_DIR/fullchain.pem" | grep -q "$STATUS_HOST"; then
                SANS="-d $DOMAIN"
                openssl x509 -noout -ext subjectAltName -in "$CERT_DIR/fullchain.pem" | grep -q "www.$DOMAIN" && SANS="$SANS -d www.$DOMAIN"
                certbot certonly --webroot -w "$CORE/public" --cert-name "$DOMAIN" --expand $SANS -d "$STATUS_HOST" \
                    -m "${EMAIL:-admin@$DOMAIN}" --agree-tos --no-eff-email -n
            fi
            write_status_vhost 1
        fi
    else
        echo "INFO: status.$DOMAIN belum mengarah ke $SERVER_IP (DNS: ${RESOLVED:-tidak ada}). Tambahkan A record, lalu jalankan ulang installer."
        echo "      Sementara halaman status tersedia di $SCHEME://$HOST/_status"
    fi
fi

ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null

if [ "$SCHEME" = "https" ] && [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    log "Memasang SSL (Lets Encrypt)"
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --no-eff-email --redirect -n
fi

systemctl restart "php$PHP_VER-fpm"
log "SELESAI -> $SCHEME://$HOST"
if grep -q "ISI-API-KEY" "$API/.env"; then
    echo "PERHATIAN: isi OPENAI_API_KEY di $API/.env lalu jalankan: systemctl restart tenangin-api"
fi
