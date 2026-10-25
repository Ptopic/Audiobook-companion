#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-AudiobookCompanion}"
CONFIGURATION="${CONFIGURATION:-Debug}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AudiobookCompanion.xcodeproj}"
BUNDLE_ID="${BUNDLE_ID:-com.petar.audiobookcompanion}"
TEAM_ID="${TEAM_ID:-RFRVD795TK}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedDataDevice}"
DEVICE_ID="${DEVICE_ID:-}"

cd "$ROOT_DIR"

if [[ -z "$DEVICE_ID" ]]; then
  devices_json="$(mktemp -t audiobook-companion-devices).json"
  xcrun devicectl list devices --json-output "$devices_json" >/dev/null
  DEVICE_ID="$(/usr/bin/python3 - "$devices_json" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

seen = []
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    platform = hardware.get("platform")
    device_type = hardware.get("deviceType", "")
    pairing_state = connection.get("pairingState")
    tunnel_state = connection.get("tunnelState")
    name = props.get("name") or hardware.get("name") or "Unnamed"
    udid = hardware.get("udid") or device.get("identifier")

    if platform == "iOS" and device_type == "iPhone":
        seen.append(f"{name} ({udid}) pairing={pairing_state} tunnel={tunnel_state}")
        if pairing_state == "paired" and tunnel_state != "unavailable":
            print(udid)
            raise SystemExit

print("No available iPhone found for devicectl install.", file=sys.stderr)
if seen:
    print("Paired iPhones seen:", file=sys.stderr)
    for item in seen:
        print(f"  - {item}", file=sys.stderr)
print("Unlock the iPhone, keep it on the same Wi-Fi or connect it by USB, trust this Mac, then retry.", file=sys.stderr)
raise SystemExit(1)
PY
)"
fi

echo "==> Building $SCHEME for device $DEVICE_ID"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

app_path="$(find "$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos" -maxdepth 1 -name "${SCHEME}.app" -print -quit)"
if [[ -z "$app_path" ]]; then
  echo "Built app was not found under $DERIVED_DATA_PATH." >&2
  exit 1
fi

echo "==> Installing $app_path"
xcrun devicectl device install app --device "$DEVICE_ID" "$app_path"

echo "==> Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID"

echo "==> Done"
echo "Scheme: $SCHEME"
echo "Device: $DEVICE_ID"
echo "Bundle: $BUNDLE_ID"
