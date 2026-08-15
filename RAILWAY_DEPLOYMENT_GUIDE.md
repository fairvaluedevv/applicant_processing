# Railway Deployment Guide for Applicant Processing

This guide provides accurate, verified instructions for hosting Frappe v15 + Applicant Processing on Railway.

---

## 1. Environment & Stack Versions Verified

| Component | Exact Version in Project |
|---|---|
| **Python** | `3.12.3` |
| **Node.js** | `v20.20.2` (LTS) |
| **Yarn** | `1.22.22` |
| **Frappe Framework** | `v15.116.1` |
| **MariaDB** | `10.11.14` (LTS) |
| **Redis** | `7.0.15` |
| **PDF Generator** | `wkhtmltopdf` (with Qt) |

---

## 2. Why MariaDB is Not in the Default "Add Database" Menu
Railway's quick database menu only shows *PostgreSQL, MySQL, Redis, MongoDB*.
However, **Frappe requires MariaDB 10.6+ / 10.11+**. 

On Railway, you deploy MariaDB in 10 seconds via **"Docker Image"** $\rightarrow$ `mariadb:10.11`.

---

## 3. Step-by-Step Railway Setup

### Step 1: Deploy MariaDB (Docker Image)
1. Open your project on Railway.
2. Click **"+ New"** $\rightarrow$ **"Docker Image"**.
3. Type: `mariadb:10.11` and press Enter.
4. Go to the new MariaDB service $\rightarrow$ **"Variables"** and add:
   - `MARIADB_ROOT_PASSWORD` = `YourSecureRootPass123!`
   - `MARIADB_DATABASE` = `frappe`
   - `MARIADB_USER` = `frappe`
   - `MARIADB_PASSWORD` = `YourFrappeDbPass123!`
5. Go to **"Settings"** $\rightarrow$ **"Volumes"** $\rightarrow$ click **"Add Volume"**:
   - Mount Path: `/var/lib/mysql`
   *(This ensures your database is permanently saved across deploys).*
6. In **"Settings"** $\rightarrow$ **"Deploy"** $\rightarrow$ **"Custom Start Command"**, enter:
   ```text
   mysqld --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --innodb-file-format=Barracuda
   ```

---

### Step 2: Deploy Redis
1. Click **"+ New"** $\rightarrow$ **"Database"** $\rightarrow$ **"Add Redis"**.
2. Railway will provision Redis and automatically create `REDIS_URL` / `REDIS_PRIVATE_URL`.

---

### Step 3: Deploy the Applicant Processing App (This Repo)
1. Click **"+ New"** $\rightarrow$ **"GitHub Repo"** $\rightarrow$ select your repository.
2. Railway will automatically pick up `railway.json` and build using our pre-configured [Dockerfile](file:///c:/Users/fdv/frappe-bench/Dockerfile).
3. Go to the App Service $\rightarrow$ **"Variables"** and add:

| Variable Name | Value | Note |
|---|---|---|
| `DB_HOST` | `${{mariadb.RAILWAY_PRIVATE_DOMAIN}}` | Private network hostname of your MariaDB service |
| `DB_PORT` | `3306` | MariaDB port |
| `DB_USER` | `frappe` (or `root`) | MariaDB username |
| `DB_PASSWORD` | `${{mariadb.MARIADB_PASSWORD}}` | Reference to MariaDB password |
| `DB_NAME` | `frappe` | Database name |
| `REDIS_URL` | `${{Redis.REDIS_PRIVATE_URL}}` | Reference to Redis private URL |
| `SITE_NAME` | `applicant-processing.railway.internal` | Or your custom domain |
| `ADMIN_PASSWORD` | `YourAdminPassword123!` | Initial Frappe Administrator login password |

---

### Step 4: Expose Public Domain
1. In the App Service $\rightarrow$ **"Settings"** $\rightarrow$ **"Networking"**, click **"Generate Domain"** (or attach your own custom domain).
2. Open the URL in your browser.
3. Log in with:
   - **Username**: `Administrator`
   - **Password**: `<Your ADMIN_PASSWORD>`
