#!/bin/bash
set -e

# Detect Railway domain or fallback to configured SITE_NAME
DETECTED_DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-${RAILWAY_STATIC_URL:-}}"
DETECTED_DOMAIN="${DETECTED_DOMAIN#https://}"
DETECTED_DOMAIN="${DETECTED_DOMAIN%/}"

SITE_NAME="${SITE_NAME:-${DETECTED_DOMAIN:-applicant-processing.railway.internal}}"
PORT="${PORT:-8000}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# Support both MariaDB Docker image variables and Railway MySQL variables
DB_HOST="${DB_HOST:-${MARIADB_HOST:-${MYSQLHOST:-mariadb}}}"
DB_PORT="${DB_PORT:-${MARIADB_PORT:-${MYSQLPORT:-3306}}}"
DB_NAME="${DB_NAME:-${MARIADB_DATABASE:-${MYSQLDATABASE:-frappe}}}"
DB_USER="${DB_USER:-${MARIADB_USER:-root}}"
DB_PASSWORD="${DB_PASSWORD:-${MARIADB_PASSWORD:-${MYSQLPASSWORD:-${MARIADB_ROOT_PASSWORD:-root}}}}"

# Robust Redis URL construction supporting Railway Redis variables
if [ -n "$REDIS_PRIVATE_URL" ]; then
  REDIS_URL="$REDIS_PRIVATE_URL"
elif [ -n "$REDIS_URL" ] && [[ "$REDIS_URL" == redis*://*:*@* ]]; then
  # Already full authenticated URL
  :
elif [ -n "$REDISHOST" ]; then
  if [ -n "$REDISPASSWORD" ]; then
    REDIS_URL="redis://default:${REDISPASSWORD}@${REDISHOST}:${REDISPORT:-6379}"
  else
    REDIS_URL="redis://${REDISHOST}:${REDISPORT:-6379}"
  fi
elif [ -n "$REDIS_URL" ]; then
  if [[ "$REDIS_URL" != redis://* ]] && [[ "$REDIS_URL" != rediss://* ]]; then
    REDIS_URL="redis://${REDIS_URL}"
  fi
  # If no port specified, append :6379
  if [[ "$REDIS_URL" =~ ^redis://[^:]+$ ]]; then
    REDIS_URL="${REDIS_URL}:6379"
  fi
  if [ -n "$REDISPASSWORD" ] && [[ "$REDIS_URL" != *"@"* ]]; then
    REDIS_URL="${REDIS_URL/redis:\/\//redis:\/\/default:${REDISPASSWORD}@}"
  fi
else
  REDIS_URL="redis://redis:6379"
fi

REDIS_CACHE_URL="${REDIS_CACHE_URL:-${REDIS_URL}}"
REDIS_QUEUE_URL="${REDIS_QUEUE_URL:-${REDIS_URL}}"

echo "=========================================================="
echo " Starting Applicant Processing App on Railway"
echo " Site Name:   $SITE_NAME"
echo " Detected:    $DETECTED_DOMAIN"
echo " Port:        $PORT"
echo " DB Host:     $DB_HOST:$DB_PORT"
echo " DB Name:     $DB_NAME"
echo " Redis URL:   $REDIS_URL"
echo "=========================================================="

cd /home/frappe/frappe-bench

export PYTHONPATH="/home/frappe/frappe-bench/apps/frappe:/home/frappe/frappe-bench/apps/applicant_processing:/home/frappe/frappe-bench/sites:${PYTHONPATH}"

# Ensure bench logs directory exists
mkdir -p /home/frappe/frappe-bench/logs

# Ensure clean apps.txt
printf "frappe\napplicant_processing\n" > sites/apps.txt

# 1. Update common_site_config.json with default_site & Redis URLs
cat <<EOF > sites/common_site_config.json
{
  "auto_update": false,
  "background_workers": 1,
  "default_site": "${SITE_NAME}",
  "developer_mode": 0,
  "dns_multitenant": false,
  "file_watcher_port": 6787,
  "gunicorn_workers": 2,
  "rebase_on_pull": false,
  "redis_cache": "${REDIS_CACHE_URL}",
  "redis_queue": "${REDIS_QUEUE_URL}",
  "redis_socketio": "${REDIS_CACHE_URL}",
  "restart_supervisor_on_update": false,
  "restart_systemd_on_update": false,
  "serve_default_site": true,
  "socketio_port": 9000,
  "webserver_port": ${PORT}
}
EOF

# 2. Wait for Database
echo "Waiting for Database connection at $DB_HOST:$DB_PORT..."
until nc -z -v -w30 "$DB_HOST" "$DB_PORT" 2>/dev/null; do
  echo "Database is not available yet. Retrying in 3 seconds..."
  sleep 3
done
echo "Database is reachable!"

# Find working MariaDB password and synchronize user 'frappe' and 'root' passwords
for P in "$MARIADB_ROOT_PASSWORD" "$DB_PASSWORD" "$MYSQLPASSWORD" "$MYSQL_ROOT_PASSWORD" "root" ""; do
  if mariadb -h "$DB_HOST" -P "$DB_PORT" -u root -p"$P" -e "
    CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS 'frappe'@'%' IDENTIFIED BY '$DB_PASSWORD';
    ALTER USER 'frappe'@'%' IDENTIFIED BY '$DB_PASSWORD';
    GRANT ALL PRIVILEGES ON *.* TO 'frappe'@'%' WITH GRANT OPTION;
    GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO 'frappe'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
  " >/dev/null 2>&1; then
    echo "Root authenticated and synchronized credentials for 'frappe'@'%'."
    break
  fi
done

# 3. Create site directory and all required subdirectories
mkdir -p "sites/$SITE_NAME/logs"
mkdir -p "sites/$SITE_NAME/public/files"
mkdir -p "sites/$SITE_NAME/private/files"
mkdir -p "sites/$SITE_NAME/private/backups"
touch "sites/$SITE_NAME/logs/frappe.log"
touch "sites/$SITE_NAME/logs/frappe.web.log"

# 4. Check if site is fully initialized with core tables (e.g. tabUser)
USER_TABLE_EXISTS=$(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "frappe" -p"$DB_PASSWORD" -D "$DB_NAME" -e "SHOW TABLES LIKE 'tabUser';" 2>/dev/null | grep tabUser || true)

if [ -z "$USER_TABLE_EXISTS" ]; then
  echo "=========================================================="
  echo " Initializing full Frappe site: $SITE_NAME..."
  echo "=========================================================="
  ./env/bin/python -m frappe.utils.bench_helper frappe new-site "$SITE_NAME" \
    --db-host "$DB_HOST" \
    --db-port "$DB_PORT" \
    --db-name "$DB_NAME" \
    --db-password "$DB_PASSWORD" \
    --db-root-username "root" \
    --db-root-password "$DB_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app applicant_processing \
    --no-setup-db \
    --set-default \
    --force \
    --verbose
else
  echo "=========================================================="
  echo " Existing database detected. Running migrations on: $SITE_NAME..."
  echo "=========================================================="
  cat <<EOF > "sites/$SITE_NAME/site_config.json"
{
  "db_name": "${DB_NAME}",
  "db_password": "${DB_PASSWORD}",
  "db_type": "mariadb",
  "db_host": "${DB_HOST}",
  "db_port": ${DB_PORT},
  "db_user": "frappe"
}
EOF
  ./env/bin/python -m frappe.utils.bench_helper frappe --site "$SITE_NAME" migrate || true
  ./env/bin/python -m frappe.utils.bench_helper frappe --site "$SITE_NAME" install-app applicant_processing || true
  if [ -n "$ADMIN_PASSWORD" ]; then
    ./env/bin/python -m frappe.utils.bench_helper frappe --site "$SITE_NAME" set-admin-password "$ADMIN_PASSWORD" || true
  fi
fi

# Link any detected domain alias to the site folder
if [ -n "$DETECTED_DOMAIN" ] && [ "$DETECTED_DOMAIN" != "$SITE_NAME" ]; then
  echo "Creating symlink alias from $DETECTED_DOMAIN to $SITE_NAME..."
  ln -sfn "$SITE_NAME" "sites/$DETECTED_DOMAIN" || true
fi

echo "$SITE_NAME" > sites/currentsite.txt

echo "=========================================================="
echo " Starting production web server on 0.0.0.0:$PORT..."
echo "=========================================================="

exec ../env/bin/gunicorn \
  --bind "0.0.0.0:${PORT}" \
  --workers 2 \
  --threads 4 \
  --timeout 120 \
  --worker-class gthread \
  --chdir /home/frappe/frappe-bench/sites \
  frappe.app:application
