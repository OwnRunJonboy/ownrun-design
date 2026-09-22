#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${OWNRUN_DATA_DIR:-/data}"
SECRETS_FILE="${DATA_DIR}/secrets.env"
RUNNER_ENV="${DATA_DIR}/runner.env"
STORAGE_DIR="/opt/ownrun/server/storage"

mkdir -p "${DATA_DIR}/workspace" "${DATA_DIR}/kb" \
    "${STORAGE_DIR}/kb" "${STORAGE_DIR}/artifacts" /run/php

persist_secret() {
    local key="$1"
    local value="$2"
    mkdir -p "${DATA_DIR}"
    touch "${SECRETS_FILE}"
    if grep -q "^${key}=" "${SECRETS_FILE}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${SECRETS_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${SECRETS_FILE}"
    fi
}

secret_from_env() {
    case "$1" in
        OWNRUN_JWT_SECRET) printf '%s' "${OWNRUN_JWT_SECRET:-}" ;;
        OWNRUN_RUNNER_TOKEN) printf '%s' "${OWNRUN_RUNNER_TOKEN:-}" ;;
        *) printf '' ;;
    esac
}

load_or_make_secret() {
    local key="$1"
    local current
    current="$(secret_from_env "${key}")"
    if [[ -n "${current}" ]]; then
        persist_secret "${key}" "${current}"
        printf '%s' "${current}"
        return
    fi
    if [[ -f "${SECRETS_FILE}" ]]; then
        local from_file
        from_file="$(grep -E "^${key}=" "${SECRETS_FILE}" | head -n1 | cut -d= -f2- || true)"
        if [[ -n "${from_file}" ]]; then
            printf '%s' "${from_file}"
            return
        fi
    fi
    local generated
    generated="$(openssl rand -hex 32)"
    persist_secret "${key}" "${generated}"
    printf '%s' "${generated}"
}

export OWNRUN_JWT_SECRET="$(load_or_make_secret OWNRUN_JWT_SECRET)"
export OWNRUN_RUNNER_TOKEN="$(load_or_make_secret OWNRUN_RUNNER_TOKEN)"

chown -R www-data:www-data "${STORAGE_DIR}"
chown -R ownrun:ownrun "${DATA_DIR}"

echo "Waiting for MariaDB at ${OWNRUN_DB_HOST}:${OWNRUN_DB_PORT}…"
php -r '
$host = getenv("OWNRUN_DB_HOST") ?: "db";
$port = (int) (getenv("OWNRUN_DB_PORT") ?: 3306);
$name = getenv("OWNRUN_DB_NAME") ?: "ownrun";
$user = getenv("OWNRUN_DB_USER") ?: "ownrun";
$pass = getenv("OWNRUN_DB_PASS") ?: "ownrun";
$dsn = sprintf("mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4", $host, $port, $name);
$deadline = time() + 90;
$last = "";
while (time() < $deadline) {
    try {
        new PDO($dsn, $user, $pass, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        echo "Database is ready.\n";
        exit(0);
    } catch (Throwable $e) {
        $last = $e->getMessage();
        fwrite(STDERR, "DB not ready: {$last}\n");
        sleep(2);
    }
}
fwrite(STDERR, "Timed out waiting for database: {$last}\n");
exit(1);
'

php /opt/ownrun/generate-config.php
chown www-data:www-data /opt/ownrun/server/config.php
chmod 640 /opt/ownrun/server/config.php

php /opt/ownrun/server/scripts/setup.php \
    --username="${OWNRUN_ADMIN_USER:-admin}" \
    --password="${OWNRUN_ADMIN_PASSWORD:-ownrun}" \
    --runner-name="${OWNRUN_RUNNER_NAME:-home}" \
    --runner-token="${OWNRUN_RUNNER_TOKEN}" \
    --update-password

# schema.sql uses CREATE IF NOT EXISTS; apply additive migrations on existing volumes.
for migrate in /opt/ownrun/server/scripts/migrate_*.php; do
    echo "Running $(basename "${migrate}")…"
    php "${migrate}"
done

cat > "${RUNNER_ENV}" <<EOF
OWNRUN_SERVER_URL=http://127.0.0.1
OWNRUN_RUNNER_TOKEN=${OWNRUN_RUNNER_TOKEN}
OWNRUN_POLL_INTERVAL=${OWNRUN_POLL_INTERVAL:-5}
OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://ollama:11434}
OWNRUN_TIMEZONE=${OWNRUN_TIMEZONE:-UTC}
OWNRUN_AGENT_WORKSPACE=${DATA_DIR}/workspace
OWNRUN_KB_DIR=${DATA_DIR}/kb
OWNRUN_KB_EMBED_MODEL=${OWNRUN_KB_EMBED_MODEL:-nomic-embed-text}
OWNRUN_SD_ENABLED=${OWNRUN_SD_ENABLED:-0}
OLLAMA_API_KEY=${OLLAMA_API_KEY:-}
HOME=${DATA_DIR}
EOF
chown ownrun:ownrun "${RUNNER_ENV}"
chmod 600 "${RUNNER_ENV}"

# supervisord cannot source a file; export into the supervisor program env.
set -a
# shellcheck disable=SC1090
source "${RUNNER_ENV}"
set +a

echo "OwnRun AIO ready."
echo "  UI:      http://localhost:${OWNRUN_PUBLISH_PORT:-8080}"
echo "  login:   ${OWNRUN_ADMIN_USER:-admin} / ${OWNRUN_ADMIN_PASSWORD:-ownrun}"
echo "  health:  /api/index.php/health"

exec "$@"
