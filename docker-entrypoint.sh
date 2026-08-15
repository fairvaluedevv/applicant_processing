#!/bin/bash
set -e

cd /home/frappe/frappe-bench

export PYTHONPATH="/home/frappe/frappe-bench/apps/frappe:/home/frappe/frappe-bench/apps/applicant_processing:/home/frappe/frappe-bench/sites:${PYTHONPATH}"

# Ensure bench logs and sites directory exist
mkdir -p /home/frappe/frappe-bench/logs
mkdir -p /home/frappe/frappe-bench/sites

# Ensure clean apps.txt in bench root and sites directory
printf "frappe\napplicant_processing\n" > /home/frappe/frappe-bench/sites/apps.txt
cp /home/frappe/frappe-bench/sites/apps.txt /home/frappe/frappe-bench/apps.txt

# 1. Initialize environment, parse Redis URL and write valid common_site_config.json via Python
./env/bin/python - <<'EOF'
import os, json, urllib.parse

def clean(v):
    if v is None:
        return ""
    s = str(v).strip()
    # Strip backslashes, quotes, and whitespace
    s = s.replace('\\"', '').replace("\\'", '').strip('"').strip("'").strip('\\').replace("\r", "").replace("\n", "").strip()
    return s

# 1. Detect Domain & Site Name
detected = clean(os.environ.get("RAILWAY_PUBLIC_DOMAIN") or os.environ.get("RAILWAY_STATIC_URL") or "")
if detected.startswith("https://"):
    detected = detected[8:]
elif detected.startswith("http://"):
    detected = detected[7:]
detected = detected.rstrip("/")

site_name = clean(os.environ.get("SITE_NAME") or detected or "applicant-processing.railway.internal")
port_val = clean(os.environ.get("PORT") or "8000")
try:
    port = int(port_val)
except ValueError:
    port = 8000

# 2. Database variables
db_host = clean(os.environ.get("DB_HOST") or os.environ.get("MARIADB_HOST") or os.environ.get("MYSQLHOST") or "mariadb.railway.internal")
db_port_val = clean(os.environ.get("DB_PORT") or os.environ.get("MARIADB_PORT") or os.environ.get("MYSQLPORT") or "3306")
try:
    db_port = int(db_port_val)
except ValueError:
    db_port = 3306
db_name = clean(os.environ.get("DB_NAME") or os.environ.get("MARIADB_DATABASE") or os.environ.get("MYSQLDATABASE") or "frappe")
db_user = clean(os.environ.get("DB_USER") or os.environ.get("MARIADB_USER") or "frappe")
db_password = clean(os.environ.get("DB_PASSWORD") or os.environ.get("MARIADB_PASSWORD") or os.environ.get("MYSQLPASSWORD") or os.environ.get("MARIADB_ROOT_PASSWORD") or "root")
admin_password = clean(os.environ.get("ADMIN_PASSWORD") or "admin")

# 3. Resolve Redis URL & Password
redis_raw = clean(os.environ.get("REDIS_PRIVATE_URL") or os.environ.get("REDIS_URL") or os.environ.get("REDIS_PUBLIC_URL") or "")
redis_pw = clean(os.environ.get("REDISPASSWORD") or os.environ.get("REDIS_PASSWORD") or os.environ.get("REDIS_AUTH") or "")
redis_host = clean(os.environ.get("REDISHOST") or os.environ.get("REDIS_HOST") or "")
redis_port = clean(os.environ.get("REDISPORT") or os.environ.get("REDIS_PORT") or "6379")

# Scan all env vars for fallback
for k, v in os.environ.items():
    cv = clean(v)
    if not redis_raw and ("REDIS" in k.upper() or "CACHE" in k.upper()) and ("redis://" in cv or "rediss://" in cv):
        redis_raw = cv
    if not redis_pw and "REDIS" in k.upper() and ("PASS" in k.upper() or "SECRET" in k.upper() or "AUTH" in k.upper()):
        redis_pw = cv
    if not redis_host and "REDIS" in k.upper() and "HOST" in k.upper() and cv:
        redis_host = cv

h = "redis.railway.internal"
p = 6379
pw = redis_pw
u = "default"

if redis_raw and len(redis_raw) > 2:
    if not (redis_raw.startswith("redis://") or redis_raw.startswith("rediss://")):
        redis_raw = "redis://" + redis_raw
    try:
        parsed = urllib.parse.urlparse(redis_raw)
        parsed_h = clean(parsed.hostname)
        if parsed_h and len(parsed_h) > 1 and parsed_h not in ('"', "'", "\\"):
            h = parsed_h
        if parsed.port:
            p = parsed.port
        if parsed.password:
            pw = clean(parsed.password)
        if parsed.username:
            u = clean(parsed.username)
    except Exception:
        pass
elif redis_host and len(redis_host) > 1 and redis_host not in ('"', "'", "\\"):
    h = redis_host

try:
    p = int(clean(redis_port) or p)
except ValueError:
    p = 6379

if pw:
    final_redis = f"redis://{u}:{pw}@{h}:{p}"
    masked_redis = f"redis://{u}:***@{h}:{p}"
else:
    final_redis = f"redis://{h}:{p}"
    masked_redis = final_redis

# 4. Write common_site_config.json
common_config = {
    "auto_update": False,
    "background_workers": 1,
    "default_site": site_name,
    "developer_mode": 0,
    "dns_multitenant": False,
    "file_watcher_port": 6787,
    "gunicorn_workers": 2,
    "rebase_on_pull": False,
    "redis_cache": final_redis,
    "redis_queue": final_redis,
    "redis_socketio": final_redis,
    "restart_supervisor_on_update": False,
    "restart_systemd_on_update": False,
    "serve_default_site": True,
    "socketio_port": 9000,
    "webserver_port": port
}

with open("sites/common_site_config.json", "w") as f:
    json.dump(common_config, f, indent=2)

with open("common_site_config.json", "w") as f:
    json.dump(common_config, f, indent=2)

with open("/tmp/frappe_env.sh", "w") as f:
    f.write(f"export SITE_NAME='{site_name}'\n")
    f.write(f"export PORT='{port}'\n")
    f.write(f"export DETECTED_DOMAIN='{detected}'\n")
    f.write(f"export DB_HOST='{db_host}'\n")
    f.write(f"export DB_PORT='{db_port}'\n")
    f.write(f"export DB_NAME='{db_name}'\n")
    f.write(f"export DB_USER='{db_user}'\n")
    f.write(f"export DB_PASSWORD='{db_password}'\n")
    f.write(f"export ADMIN_PASSWORD='{admin_password}'\n")
    f.write(f"export REDIS_URL='{final_redis}'\n")
    f.write(f"export MASKED_REDIS='{masked_redis}'\n")
    f.write(f"export REDIS_CHECK_HOST='{h}'\n")
    f.write(f"export REDIS_CHECK_PORT='{p}'\n")

print("Generated valid common_site_config.json successfully.")
EOF

source /tmp/frappe_env.sh

echo "=========================================================="
echo " Starting Applicant Processing App on Railway"
echo " Site Name:   $SITE_NAME"
echo " Detected:    $DETECTED_DOMAIN"
echo " Port:        $PORT"
echo " DB Host:     $DB_HOST:$DB_PORT"
echo " DB Name:     $DB_NAME"
echo " Redis URL:   $MASKED_REDIS"
echo "=========================================================="

# 2. Wait for Database and Redis
echo "Waiting for Database connection at $DB_HOST:$DB_PORT..."
until nc -z -v -w30 "$DB_HOST" "$DB_PORT" 2>/dev/null; do
  echo "Database is not available yet. Retrying in 3 seconds..."
  sleep 3
done
echo "Database is reachable!"

if [ -n "$REDIS_CHECK_HOST" ] && [ "$REDIS_CHECK_HOST" != "redis" ]; then
  echo "Waiting for Redis connection at $REDIS_CHECK_HOST:$REDIS_CHECK_PORT..."
  until nc -z -v -w30 "$REDIS_CHECK_HOST" "$REDIS_CHECK_PORT" 2>/dev/null; do
    echo "Redis is not available yet. Retrying in 3 seconds..."
    sleep 3
  done
  echo "Redis is reachable!"
fi

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

cd /home/frappe/frappe-bench/sites

# 3. Create site directory and all required subdirectories
mkdir -p "$SITE_NAME/logs"
mkdir -p "$SITE_NAME/public/files"
mkdir -p "$SITE_NAME/private/files"
mkdir -p "$SITE_NAME/private/backups"
touch "$SITE_NAME/logs/frappe.log"
touch "$SITE_NAME/logs/frappe.web.log"

# 4. Check if site is fully initialized with core tables (e.g. tabUser)
USER_TABLE_EXISTS=$(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "frappe" -p"$DB_PASSWORD" -D "$DB_NAME" -e "SHOW TABLES LIKE 'tabUser';" 2>/dev/null | grep tabUser || true)

if [ -z "$USER_TABLE_EXISTS" ]; then
  echo "=========================================================="
  echo " Initializing full Frappe site: $SITE_NAME..."
  echo "=========================================================="
  ../env/bin/python -m frappe.utils.bench_helper frappe new-site "$SITE_NAME" \
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
  ../env/bin/python - <<EOF
import json
cfg = {
  "db_name": "${DB_NAME}",
  "db_password": "${DB_PASSWORD}",
  "db_type": "mariadb",
  "db_host": "${DB_HOST}",
  "db_port": int("${DB_PORT}"),
  "db_user": "frappe"
}
with open("${SITE_NAME}/site_config.json", "w") as f:
    json.dump(cfg, f, indent=2)
EOF
  ../env/bin/python -m frappe.utils.bench_helper frappe --site "$SITE_NAME" migrate || true
  ../env/bin/python -m frappe.utils.bench_helper frappe --site "$SITE_NAME" install-app applicant_processing || true
  if [ -n "$ADMIN_PASSWORD" ]; then
    ../env/bin/python -m frappe.utils.bench_helper frappe --site "$SITE_NAME" set-admin-password "$ADMIN_PASSWORD" || true
  fi
fi

# Link any detected domain alias to the site folder
if [ -n "$DETECTED_DOMAIN" ] && [ "$DETECTED_DOMAIN" != "$SITE_NAME" ]; then
  echo "Creating symlink alias from $DETECTED_DOMAIN to $SITE_NAME..."
  ln -sfn "$SITE_NAME" "$DETECTED_DOMAIN" || true
fi

# Ensure frontend static assets are available
if [ ! -f "assets/assets.json" ] || [ ! -d "assets/frappe" ]; then
  echo "Assets manifest not found. Building and linking frontend assets..."
  ../env/bin/python -m frappe.utils.bench_helper frappe build || true
fi

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
  "frappe.app:application_with_statics()"
