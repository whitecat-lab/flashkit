#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="io.flashkit.FlashKit.PrivilegedHelper"
DEST_BIN="/Library/PrivilegedHelperTools/$SERVICE_NAME"
DEST_PLIST="/Library/LaunchDaemons/$SERVICE_NAME.plist"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

launchctl bootout system "$DEST_PLIST" >/dev/null 2>&1 || true
rm -f "$DEST_PLIST" "$DEST_BIN"

echo "Removed $SERVICE_NAME"
