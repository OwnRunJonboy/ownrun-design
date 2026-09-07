# syntax=docker/dockerfile:1
# OwnRun all-in-one image: Vue SPA + PHP API + Python runner.
# Run prepare-context.sh first so src/{server,web,runner} exist.
# MariaDB and Ollama are compose sidecars (see docker-compose.yml).

FROM node:22-bookworm-slim AS web-build
WORKDIR /src
COPY src/web/package.json src/web/package-lock.json ./
RUN npm ci
COPY src/web/ ./
RUN npm run build

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    OWNRUN_DB_HOST=db \
    OWNRUN_DB_PORT=3306 \
    OWNRUN_DB_NAME=ownrun \
    OWNRUN_DB_USER=ownrun \
    OWNRUN_DB_PASS=ownrun \
    OWNRUN_ADMIN_USER=admin \
    OWNRUN_ADMIN_PASSWORD=ownrun \
    OWNRUN_TIMEZONE=UTC \
    OLLAMA_BASE_URL=http://ollama:11434 \
    OWNRUN_POLL_INTERVAL=5 \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        nginx \
        openssl \
        php8.2-cli \
        php8.2-curl \
        php8.2-fpm \
        php8.2-mbstring \
        php8.2-mysql \
        php8.2-xml \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        supervisor \
        tzdata \
        gcc \
        g++ \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default \
    && mkdir -p /run/php /var/www/html /opt/ownrun /data \
    && useradd --system --home-dir /data --shell /usr/sbin/nologin ownrun

COPY src/server/ /opt/ownrun/server/
COPY src/runner/ /opt/ownrun/runner/
COPY --from=web-build /src/dist /var/www/html

RUN python3 -m venv /opt/ownrun/venv \
    && /opt/ownrun/venv/bin/pip install --upgrade pip \
    && /opt/ownrun/venv/bin/pip install --no-cache-dir -r /opt/ownrun/runner/requirements.txt \
    && mkdir -p /opt/ownrun/server/storage/kb /opt/ownrun/server/storage/artifacts \
    && chown -R www-data:www-data /opt/ownrun/server /var/www/html \
    && chown -R ownrun:ownrun /opt/ownrun/runner /opt/ownrun/venv /data

COPY nginx.conf /etc/nginx/conf.d/ownrun.conf
COPY php-ownrun.ini /etc/php/8.2/fpm/conf.d/99-ownrun.ini
COPY php-ownrun.ini /etc/php/8.2/cli/conf.d/99-ownrun.ini
COPY php-fpm-pool.conf /etc/php/8.2/fpm/pool.d/ownrun.conf
COPY supervisord.conf /etc/supervisor/conf.d/ownrun.conf
COPY generate-config.php /opt/ownrun/generate-config.php
COPY run-runner.sh /opt/ownrun/run-runner.sh
COPY docker-entrypoint.sh /opt/ownrun/docker-entrypoint.sh

RUN chmod +x /opt/ownrun/docker-entrypoint.sh /opt/ownrun/run-runner.sh \
    && rm -f /etc/php/8.2/fpm/pool.d/www.conf \
    && sed -i 's/^daemonize = yes/daemonize = no/' /etc/php/8.2/fpm/php-fpm.conf \
    && sed -i 's|^error_log = .*|error_log = /proc/self/fd/2|' /etc/php/8.2/fpm/php-fpm.conf \
    && rm -f /etc/nginx/conf.d/default.conf

EXPOSE 80
VOLUME ["/data", "/opt/ownrun/server/storage"]
HEALTHCHECK --interval=20s --timeout=5s --start-period=40s --retries=10 \
    CMD curl -fsS http://127.0.0.1/api/index.php/health || exit 1

ENTRYPOINT ["/opt/ownrun/docker-entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
