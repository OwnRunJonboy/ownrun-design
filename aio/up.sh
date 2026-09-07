#!/usr/bin/env bash
# Prepare sources and start the OwnRun all-in-one stack.
set -euo pipefail
cd "$(dirname "$0")"
./prepare-context.sh
if docker compose version >/dev/null 2>&1; then
    docker compose up --build "$@"
elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose up --build "$@"
else
    echo "Install Docker Compose (plugin v2 or docker-compose 1.29+)." >&2
    exit 1
fi
