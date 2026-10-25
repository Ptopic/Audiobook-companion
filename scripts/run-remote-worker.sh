#!/bin/bash
set -euo pipefail
umask 077

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ ! -f .env ]]; then
    echo "Worker .env is missing; rerun the installer." >&2
    exit 1
fi
set -a
source .env
set +a

exec "$PROJECT_ROOT/.venv/bin/python" -m backend.remote_worker
