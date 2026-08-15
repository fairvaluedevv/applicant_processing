#!/bin/bash
set -e

SITE_NAME="${SITE_NAME:-applicant-processing.railway.internal}"
PORT="${PORT:-8000}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# Support both MariaDB Docker image variables and Railway MySQL variables
DB_HOST="${DB_HOST:-${MARIADB_HOST:-${MYSQLHOST:-mariadb}}}"
DB_PORT="${DB_PORT:-${MARIADB_PORT:-${MYSQLPORT:-3306}}}"
DB_USER="${DB_USER:-${MARIADB_USER:-${MYSQLUSER:-root}}}"
DB_PASSWORD="${DB_PASSWORD:-${MARIADB_PASSWORD:-${MYSQLPASSWORD:-${MARIADB_ROOT_PASSWORD:-root}}}}}"
DB_NAME="${DB_NAME:-${MARIADB_DATABASE:-${MYSQLDATABASE:-frappe}}}"

# Support standard Railway Redis environment variables
REDIS_URL="${REDIS_URL:-${REDIS_PRIVATE_URL:-redis://redis:6379}}"
REDIS_CACHE_URL="${REDIS_CACHE_URL:-${REDIS_URL}}"
REDIS_QUEUE_URL="${REDIS_QUEUE_URL:-${REDIS_URL}}"

echo "=========================================================="
echo " Starting Applicant Processing App on Railway"
echo " Site Name:   $SITE_NAME"
echo " Port:        $PORT"
echo " DB Host:     $DB_HOST:$DB_PORT"
echo " DB Name:     $DB_NAME"
echo " DB User:     $DB_USER"
echo "=========================================================="

cd /home/frappe/frappe-bench

# 1. Update common_site_config.json with Redis URLs
cat <<EOF > sites/common_site_config.json
{
  "auto_update": false,
  "background_workers": 1,
  "developer_mode": 0,
  "dns_multitenant": true,
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

# 3. Setup Site Config & Database
mkdir -p "sites/$SITE_NAME"
SITE_CONFIG="sites/$SITE_NAME/site_config.json"

if [ ! -f "$SITE_CONFIG" ]; then
  echo "Creating new site config for $SITE_NAME..."
  cat <<EOF > "$SITE_CONFIG"
{
  "db_name": "${DB_NAME}",
  "db_password": "${DB_PASSWORD}",
  "db_type": "mariadb",
  "db_host": "${DB_HOST}",
  "db_port": ${DB_PORT},
  "db_user": "${DB_USER}"
}
EOF
fi

# Set default site
echo "$SITE_NAME" > sites/currentsite.txt

echo "Running migrations for site: $SITE_NAME..."
bench --site "$SITE_NAME" migrate || true

echo "Ensuring applicant_processing is installed on $SITE_NAME..."
bench --site "$SITE_NAME" install-app applicant_processing || true

# 4. Set Administrator password if specified
if [ -n "$ADMIN_PASSWORD" ]; then
  bench --site "$SITE_NAME" set-admin-password "$ADMIN_PASSWORD" || true
fi

echo "=========================================================="
echo " Setup complete! Starting Gunicorn Web Server on port $PORT..."
echo "=========================================================="

# Start Gunicorn in foreground
exec ./env/bin/gunicorn \
  --bind "0.0.0.0:${PORT}" \
  --workers 2 \
  --threads 4 \
  --timeout 120 \
  --worker-class gthread \
  --chdir /home/frappe/frappe-bench/sites \
  frappe.app:application
