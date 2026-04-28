#!/usr/bin/env bash
set -euo pipefail

# Build the helper as the invoking user first so .build/ and other workspace
# artifacts remain user-owned. The root phase should only install/bootstrap the
# already-built helper into /Library.

SERVICE_NAME="io.flashkit.FlashKit.PrivilegedHelper"
APP_BUNDLE_ID="io.flashkit.FlashKit"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_BIN="/Library/PrivilegedHelperTools/$SERVICE_NAME"
DEST_PLIST="/Library/LaunchDaemons/$SERVICE_NAME.plist"

build_helper_as_user() {
  cd "$ROOT_DIR"
  swift build --product FlashKitPrivilegedHelper >/dev/null

  local bin_path
  bin_path="$(swift build --show-bin-path)/FlashKitPrivilegedHelper"

  if [[ ! -x "$bin_path" ]]; then
    echo "Missing helper binary: $bin_path" >&2
    exit 1
  fi

  printf '%s\n' "$bin_path"
}

install_built_helper_as_root() {
  local bin_path="$1"
  local tmp_plist
  tmp_plist="$(mktemp)"
  trap 'rm -f "$tmp_plist"' EXIT

  if [[ ! -x "$bin_path" ]]; then
    echo "Missing helper binary: $bin_path" >&2
    exit 1
  fi

  cat >"$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVICE_NAME</string>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$APP_BUNDLE_ID</string>
  </array>
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
  install -m 755 "$bin_path" "$DEST_BIN"
  install -m 644 "$tmp_plist" "$DEST_PLIST"
  chown root:wheel "$DEST_BIN" "$DEST_PLIST"

  launchctl bootstrap system "$DEST_PLIST"
  launchctl kickstart -k "system/$SERVICE_NAME" >/dev/null 2>&1 || true

  echo "Installed $SERVICE_NAME"
}

if [[ "${1:-}" == "--install-built" ]]; then
  shift
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "The internal --install-built mode must run as root." >&2
    exit 2
  fi
  if [[ $# -ne 1 ]]; then
    echo "usage: $0 --install-built /absolute/path/to/FlashKitPrivilegedHelper" >&2
    exit 2
  fi
  install_built_helper_as_root "$1"
  exit 0
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "Run this script as a normal user. It will build the helper first, then prompt for sudo only for the install step." >&2
  exit 2
fi

BUILT_HELPER_PATH="$(build_helper_as_user)"
exec sudo "$SCRIPT_PATH" --install-built "$BUILT_HELPER_PATH"
