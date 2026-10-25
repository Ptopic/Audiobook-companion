#!/bin/bash
set -euo pipefail
umask 077

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="$HOME/Library/Application Support/KindleAudioBooks/worker"
LABEL="com.petartopic.kindle-audio-books.remote-worker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="gui/$(id -u)/$LABEL"

if [[ ! -x "$PROJECT_ROOT/.venv/bin/python" ]]; then
    echo "Create the project .venv and install requirements.txt first." >&2
    exit 1
fi
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
    echo "Create the project .env with S3 settings and AUDIOBOOK_REMOTE_TOKEN first." >&2
    exit 1
fi
if ! (unset AUDIOBOOK_REMOTE_TOKEN; set -a; source "$PROJECT_ROOT/.env"; [[ -n "${AUDIOBOOK_REMOTE_TOKEN:-}" ]]); then
    echo "Add AUDIOBOOK_REMOTE_TOKEN to the project .env first." >&2
    exit 1
fi

if launchctl print "$SERVICE" >/dev/null 2>&1; then
    launchctl bootout "$SERVICE"
fi

mkdir -p "$HOME/Library/LaunchAgents" "$RUNTIME_ROOT/backend" "$RUNTIME_ROOT/scripts" "$RUNTIME_ROOT/.venv" "$RUNTIME_ROOT/data"
chmod 700 "$RUNTIME_ROOT" "$RUNTIME_ROOT/data"
rsync -a --delete --exclude '__pycache__/' "$PROJECT_ROOT/backend/" "$RUNTIME_ROOT/backend/"
rsync -a --delete "$PROJECT_ROOT/.venv/" "$RUNTIME_ROOT/.venv/"
install -m 700 "$PROJECT_ROOT/scripts/run-remote-worker.sh" "$RUNTIME_ROOT/scripts/run-remote-worker.sh"
install -m 600 "$PROJECT_ROOT/.env" "$RUNTIME_ROOT/.env"

python3 - "$RUNTIME_ROOT" "$PROJECT_ROOT" <<'PY'
import sys
from pathlib import Path

runtime, original = (Path(value).resolve() for value in sys.argv[1:])
for directory in (runtime / "backend", runtime / ".venv", runtime / "scripts"):
    for path in directory.rglob("*"):
        if path.is_symlink() and path.resolve().is_relative_to(original):
            raise SystemExit(f"Staged runtime links back to the Desktop project: {path}")
PY

(cd "$RUNTIME_ROOT" && .venv/bin/python -c 'import backend.remote_worker')

python3 - "$PLIST" "$RUNTIME_ROOT" "$LABEL" <<'PY'
import plistlib
import sys
from pathlib import Path

destination, runtime_root, label = sys.argv[1:]
project = Path(runtime_root)
settings = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", str(project / "scripts" / "run-remote-worker.sh")],
    "WorkingDirectory": str(project),
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 60,
    "StandardOutPath": str(project / "data" / "remote-worker.stdout.log"),
    "StandardErrorPath": str(project / "data" / "remote-worker.stderr.log"),
}
with Path(destination).open("wb") as out:
    plistlib.dump(settings, out)
PY

plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed and started $LABEL. Logs: $RUNTIME_ROOT/data/remote-worker.stderr.log"
