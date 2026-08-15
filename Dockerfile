FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DEBIAN_FRONTEND=noninteractive \
    SHELL=/bin/bash

# 1. Install OS system dependencies, Node.js 20 LTS, and wkhtmltopdf
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    build-essential \
    default-libmysqlclient-dev \
    mariadb-client \
    redis-tools \
    netcat-traditional \
    libfontconfig1 \
    libxrender1 \
    libxext6 \
    fonts-dejavu \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    wkhtmltopdf \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g yarn@1.22.22 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Create non-root frappe user
RUN useradd -ms /bin/bash -u 1000 frappe
USER frappe
WORKDIR /home/frappe

# 3. Create bench folder and Python virtual environment
RUN mkdir -p /home/frappe/frappe-bench/apps \
    && mkdir -p /home/frappe/frappe-bench/sites \
    && mkdir -p /home/frappe/frappe-bench/logs \
    && mkdir -p /home/frappe/frappe-bench/config \
    && python3 -m venv /home/frappe/frappe-bench/env

ENV PATH="/home/frappe/frappe-bench/env/bin:${PATH}"

# 4. Install Frappe core into venv
WORKDIR /home/frappe/frappe-bench
COPY --chown=frappe:frappe apps/frappe apps/frappe
RUN ./env/bin/pip install --no-cache-dir -e ./apps/frappe

# 5. Copy and install applicant_processing app
COPY --chown=frappe:frappe apps/applicant_processing apps/applicant_processing
RUN ./env/bin/pip install --no-cache-dir -e ./apps/applicant_processing

# 6. Copy configuration and sites baseline
COPY --chown=frappe:frappe sites/apps.txt sites/apps.txt
COPY --chown=frappe:frappe docker-entrypoint.sh /home/frappe/docker-entrypoint.sh

USER root
RUN chmod +x /home/frappe/docker-entrypoint.sh
USER frappe

# 7. Build production static assets
RUN cd sites && ../env/bin/python -m frappe.utils.bench_helper frappe build --app applicant_processing || true

EXPOSE 8000

ENTRYPOINT ["/home/frappe/docker-entrypoint.sh"]
