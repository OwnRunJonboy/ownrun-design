#!/usr/bin/env bash
# Copy the three OwnRun repos into aio/src/ for the Docker build.
# Reads OWNRUN_*_DIR from .env when present.
set -euo pipefail

cd "$(dirname "$0")"

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

SERVER_DIR="${OWNRUN_SERVER_DIR:-../ownrun-server}"
WEB_DIR="${OWNRUN_WEB_DIR:-../ownrun-web}"
RUNNER_DIR="${OWNRUN_RUNNER_DIR:-../ownrun-runner}"

need_dir() {
    local path="$1"
    local label="$2"
    if [[ ! -d "${path}" ]]; then
        echo "Missing ${label} at ${path}" >&2
        echo "Set ${label} in .env (see .env.example)." >&2
        exit 1
    fi
}

need_dir "${SERVER_DIR}" "OWNRUN_SERVER_DIR"
need_dir "${WEB_DIR}" "OWNRUN_WEB_DIR"
need_dir "${RUNNER_DIR}" "OWNRUN_RUNNER_DIR"

mkdir -p src

copy_tree() {
    local from="$1"
    local to="$2"
    shift 2
    mkdir -p "${to}"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$@" "${from}/" "${to}/"
    else
        rm -rf "${to}"
        mkdir -p "${to}"
        tar -C "${from}" --exclude-vcs -cf - . | tar -C "${to}" -xf -
    fi
}

copy_tree "${SERVER_DIR}" src/server \
    --exclude .git --exclude storage --exclude config.php --exclude '*.log'
copy_tree "${WEB_DIR}" src/web \
    --exclude .git --exclude node_modules --exclude dist --exclude tsconfig.tsbuildinfo
copy_tree "${RUNNER_DIR}" src/runner \
    --exclude .git --exclude .venv --exclude ownrun.venv --exclude models \
    --exclude '*.gguf' --exclude __pycache__ --exclude '*.egg-info' \
    --exclude nohup.out --exclude dist --exclude build

if [[ ! -f src/web/package-lock.json ]]; then
    echo "ownrun-web is missing package-lock.json (needed for npm ci)." >&2
    exit 1
fi
if [[ ! -f src/server/api/index.php ]]; then
    echo "ownrun-server copy looks incomplete." >&2
    exit 1
fi
if [[ ! -f src/runner/run.py ]]; then
    echo "ownrun-runner copy looks incomplete." >&2
    exit 1
fi

echo "Staged sources in src/ (server, web, runner)."
