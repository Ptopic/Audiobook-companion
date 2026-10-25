#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/build-adhoc-ipa.sh"

ipa_path="$(find "$ROOT_DIR/build/adhoc" -maxdepth 1 -name "*.ipa" -print -quit)"
if [[ -z "$ipa_path" ]]; then
  echo "No IPA was found after build." >&2
  exit 1
fi

IPA_PATH="$ipa_path" "$ROOT_DIR/scripts/publish-ota.sh"
