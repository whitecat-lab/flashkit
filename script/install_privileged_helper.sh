#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="io.flashkit.FlashKit.PrivilegedHelper"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_BIN="/Library/PrivilegedHelperTools/$SERVICE_NAME"
DEST_PLIST="/Library/LaunchDaemons/$SERVICE_NAME.plist"
TMP_PLIST="$(mktemp)"
trap 'rm -f "$TMP_PLIST"' EXIT

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

cd "$ROOT_DIR"
swift build --product FlashKitPrivilegedHelper >/dev/null
BIN_PATH="$(swift build --show-bin-path)/FlashKitPrivilegedHelper"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Missing helper binary: $BIN_PATH" >&2
  exit 1
fi

cat >"$TMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVICE_NAME</string>
  <key>MachServices</key>
  <dict>
    <key>$SERVICE_NAME</key>
    <true/>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST_BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

launchctl bootout system "$DEST_PLIST" >/dev/null 2>&1 || true

install -d -m 755 /Library/PrivilegedHelperTools
install -d -m 755 /Library/LaunchDaemons
install -m 755 "$BIN_PATH" "$DEST_BIN"
install -m 644 "$TMP_PLIST" "$DEST_PLIST"
chown root:wheel "$DEST_BIN" "$DEST_PLIST"

launchctl bootstrap system "$DEST_PLIST"
launchctl kickstart -k "system/$SERVICE_NAME" >/dev/null 2>&1 || true

echo "Installed $SERVICE_NAME"
