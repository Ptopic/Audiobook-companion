#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISSION_CONTROL_PUBLIC_DIR="${MISSION_CONTROL_PUBLIC_DIR:-/Users/petartopic/Desktop/Petar/get-stuff-done/apps/mission-control-app/ui/public}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://frontend.petartopic.com}"
APP_NAME="${APP_NAME:-Audiobook Companion}"
BUNDLE_ID="${BUNDLE_ID:-com.petar.audiobookcompanion}"
VERSION="${VERSION:-1.0}"
CACHE_BUSTER="${CACHE_BUSTER:-$(date +%Y%m%d%H%M)}"
IPA_PATH="${IPA_PATH:-}"
RELEASE_SLUG="${RELEASE_SLUG:-latest}"
PUBLIC_RELEASE_PATH="${PUBLIC_RELEASE_PATH:-my-mind/ota/audiobook-companion/$RELEASE_SLUG}"
TARGET_DIR="$MISSION_CONTROL_PUBLIC_DIR/$PUBLIC_RELEASE_PATH"
VPS_OTA_TARGET="${VPS_OTA_TARGET:-}"

if [[ -z "$IPA_PATH" ]]; then
  IPA_PATH="$(find "$ROOT_DIR/build/adhoc" -maxdepth 1 -name "*.ipa" -print -quit 2>/dev/null || true)"
fi

if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  cat >&2 <<'EOF'
No IPA found.

Build first:
  ./scripts/build-adhoc-ipa.sh

Or pass:
  IPA_PATH=/path/to/AudiobookCompanion.ipa ./scripts/publish-ota.sh
EOF
  exit 1
fi

if ! IPA_BUILD_NUMBER="$(unzip -p "$IPA_PATH" 'Payload/*.app/Info.plist' | plutil -extract CFBundleVersion raw -o - -)" || [[ -z "$IPA_BUILD_NUMBER" ]]; then
  echo "Could not read CFBundleVersion from IPA: $IPA_PATH" >&2
  exit 1
fi

if [[ ! -d "$MISSION_CONTROL_PUBLIC_DIR" ]]; then
  echo "MISSION_CONTROL_PUBLIC_DIR does not exist: $MISSION_CONTROL_PUBLIC_DIR" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
cp "$IPA_PATH" "$TARGET_DIR/AudiobookCompanion.ipa"

IPA_URL="$PUBLIC_BASE_URL/$PUBLIC_RELEASE_PATH/AudiobookCompanion.ipa"
MANIFEST_URL="$PUBLIC_BASE_URL/$PUBLIC_RELEASE_PATH/manifest.plist"
IPA_INSTALL_URL="$IPA_URL?v=$CACHE_BUSTER"
MANIFEST_INSTALL_URL="$MANIFEST_URL?v=$CACHE_BUSTER"
ENCODED_MANIFEST_INSTALL_URL="$(node -e "process.stdout.write(encodeURIComponent(process.argv[1]))" "$MANIFEST_INSTALL_URL")"
INSTALL_URL="itms-services://?action=download-manifest&url=$ENCODED_MANIFEST_INSTALL_URL"

cat > "$TARGET_DIR/manifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>$IPA_INSTALL_URL</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>$BUNDLE_ID</string>
        <key>bundle-version</key>
        <string>$IPA_BUILD_NUMBER</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>$APP_NAME</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF

cat > "$TARGET_DIR/build.json" <<EOF
{
  "appName": "$APP_NAME",
  "bundleId": "$BUNDLE_ID",
  "version": "$VERSION",
  "buildNumber": "$IPA_BUILD_NUMBER",
  "cacheBuster": "$CACHE_BUSTER",
  "ipaUrl": "$IPA_URL",
  "manifestUrl": "$MANIFEST_URL",
  "installUrl": "$INSTALL_URL",
  "publishedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

cat > "$TARGET_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Install $APP_NAME</title>
    <style>
      :root { color-scheme: dark; }
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        background: #101419;
        color: #f7f3ed;
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      }
      main {
        width: min(420px, calc(100vw - 40px));
        padding: 28px;
        border-radius: 24px;
        background: #1c2028;
        box-shadow: 0 24px 80px rgba(0,0,0,.45);
      }
      h1 { margin: 0 0 10px; font-size: 28px; }
      p { color: #aeb6c2; line-height: 1.45; }
      a {
        display: flex;
        align-items: center;
        justify-content: center;
        height: 56px;
        margin-top: 22px;
        border-radius: 16px;
        color: white;
        text-decoration: none;
        font-weight: 700;
        background: #177d68;
      }
      code { color: #7dd6bd; }
    </style>
  </head>
  <body>
    <main>
      <h1>$APP_NAME</h1>
      <p>Install the latest Ad Hoc build on a registered iPhone.</p>
      <p>Version <code>$VERSION</code> · Build <code>$IPA_BUILD_NUMBER</code></p>
      <a href="$INSTALL_URL">Install on iPhone</a>
    </main>
  </body>
</html>
EOF

echo "==> OTA files published"
echo "Install page: $PUBLIC_BASE_URL/$PUBLIC_RELEASE_PATH/"
echo "Manifest:     $MANIFEST_URL"
echo "IPA:          $IPA_URL"

if [[ -n "$VPS_OTA_TARGET" ]]; then
  echo "==> Syncing OTA files to $VPS_OTA_TARGET"
  rsync -az --delete "$TARGET_DIR/" "$VPS_OTA_TARGET/"
fi
