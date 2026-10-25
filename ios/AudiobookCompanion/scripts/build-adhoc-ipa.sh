#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-AudiobookCompanion}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AudiobookCompanion.xcodeproj}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/archives/$SCHEME.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-$ROOT_DIR/build/adhoc}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/build/export-options-adhoc.plist}"
BUNDLE_ID="${BUNDLE_ID:-com.petar.audiobookcompanion}"
TEAM_ID="${TEAM_ID:-RFRVD795TK}"
PROVISIONING_PROFILE_NAME="${PROVISIONING_PROFILE_NAME:-}"
SIGNING_CERTIFICATE="${SIGNING_CERTIFICATE:-Apple Distribution}"
EXPORT_METHOD="${EXPORT_METHOD:-ad-hoc}"
COMPILE_BITCODE="${COMPILE_BITCODE:-false}"
STRIP_SWIFT_SYMBOLS="${STRIP_SWIFT_SYMBOLS:-true}"

cd "$ROOT_DIR"

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_DIR" "$ROOT_DIR/build"

plist_bool() {
  case "$1" in
    true|TRUE|1|yes|YES) printf '<true/>' ;;
    false|FALSE|0|no|NO) printf '<false/>' ;;
    *)
      echo "Invalid boolean value '$1'. Use true or false." >&2
      exit 1
      ;;
  esac
}

compile_bitcode_plist="$(plist_bool "$COMPILE_BITCODE")"
strip_swift_symbols_plist="$(plist_bool "$STRIP_SWIFT_SYMBOLS")"

echo "==> Archiving $SCHEME ($CONFIGURATION)"
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

if [[ -n "$PROVISIONING_PROFILE_NAME" ]]; then
  signing_style="manual"
  provisioning_profiles_block="
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key>
    <string>$PROVISIONING_PROFILE_NAME</string>
  </dict>"
else
  signing_style="automatic"
  provisioning_profiles_block=""
fi

cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>$signing_style</string>
  <key>signingCertificate</key>
  <string>$SIGNING_CERTIFICATE</string>$provisioning_profiles_block
  <key>compileBitcode</key>
  $compile_bitcode_plist
  <key>stripSwiftSymbols</key>
  $strip_swift_symbols_plist
</dict>
</plist>
EOF

echo "==> Exporting Ad Hoc IPA"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

ipa_path="$(find "$EXPORT_DIR" -maxdepth 1 -name "*.ipa" -print -quit)"
if [[ -z "$ipa_path" ]]; then
  echo "No IPA was exported under $EXPORT_DIR." >&2
  exit 1
fi

echo "==> IPA exported"
echo "$ipa_path"
