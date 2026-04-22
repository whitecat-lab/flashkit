#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="FlashKit"
BUNDLE_ID="io.flashkit.FlashKit"
BUILD_BINARY_NAME="FlashKit"
PRIVILEGED_HELPER_PRODUCT="FlashKitPrivilegedHelper"
PRIVILEGED_HELPER_SERVICE="io.flashkit.FlashKit.PrivilegedHelper"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_LIBRARY="$APP_CONTENTS/Library"
APP_PRIVILEGED_HELPERS="$APP_LIBRARY/PrivilegedHelperTools"
APP_LAUNCHDAEMONS="$APP_LIBRARY/LaunchDaemons"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="AppIcon"
APP_ICON_FILE="$ROOT_DIR/Resources/$APP_ICON_NAME.icns"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$BUILD_BINARY_NAME" >/dev/null 2>&1 || true

if [[ -x "$ROOT_DIR/script/bundle_helpers.sh" ]]; then
  "$ROOT_DIR/script/bundle_helpers.sh"
fi

swift build
swift build --product "$PRIVILEGED_HELPER_PRODUCT"
BUILD_BINARY="$(swift build --show-bin-path)/$BUILD_BINARY_NAME"
PRIVILEGED_HELPER_BINARY="$(swift build --show-bin-path)/$PRIVILEGED_HELPER_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
mkdir -p "$APP_PRIVILEGED_HELPERS"
mkdir -p "$APP_LAUNCHDAEMONS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -d "$ROOT_DIR/Resources" ]]; then
  cp -R "$ROOT_DIR/Resources/." "$APP_RESOURCES/"
fi

if [[ -x "$PRIVILEGED_HELPER_BINARY" ]]; then
  cp "$PRIVILEGED_HELPER_BINARY" "$APP_PRIVILEGED_HELPERS/$PRIVILEGED_HELPER_SERVICE"
  chmod +x "$APP_PRIVILEGED_HELPERS/$PRIVILEGED_HELPER_SERVICE"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
PLIST

if [[ -f "$APP_ICON_FILE" ]]; then
cat >>"$INFO_PLIST" <<PLIST
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
PLIST
fi

cat >>"$INFO_PLIST" <<PLIST
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -x "$APP_PRIVILEGED_HELPERS/$PRIVILEGED_HELPER_SERVICE" ]]; then
cat >"$APP_LAUNCHDAEMONS/$PRIVILEGED_HELPER_SERVICE.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PRIVILEGED_HELPER_SERVICE</string>
  <key>MachServices</key>
  <dict>
    <key>$PRIVILEGED_HELPER_SERVICE</key>
    <true/>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/Library/PrivilegedHelperTools/$PRIVILEGED_HELPER_SERVICE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
