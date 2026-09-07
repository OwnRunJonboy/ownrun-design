#!/usr/bin/env bash
set -euo pipefail
set -a
# shellcheck disable=SC1091
source /data/runner.env
set +a
exec /opt/ownrun/venv/bin/python /opt/ownrun/runner/run.py
