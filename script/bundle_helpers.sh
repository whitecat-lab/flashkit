#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINAL_HELPER_DIR="$ROOT_DIR/Resources/Helpers"
STAGE_ROOT="$(mktemp -d)"
HELPER_DIR="$STAGE_ROOT/Helpers"
LIB_DIR="$HELPER_DIR/lib"
MANIFEST="$HELPER_DIR/bundled-helpers.txt"

HELPERS=(
  "wimlib-imagex"
  "qemu-img"
  "mkntfs"
  "ntfsfix"
  "ntfscp"
  "ntfscat"
  "mke2fs"
  "debugfs"
  "xz"
)

trap 'rm -rf "$STAGE_ROOT"' EXIT

mkdir -p "$HELPER_DIR"
rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR"
xattr -cr "$HELPER_DIR" "$LIB_DIR" 2>/dev/null || true
rm -f "$MANIFEST"
for helper in "${HELPERS[@]}"; do
  rm -f "$HELPER_DIR/$helper"
done

resolve_helper() {
  local name="$1"
  if [[ -x "/opt/local/bin/$name" ]]; then
    printf '%s\n' "/opt/local/bin/$name"
    return 0
  fi
  if [[ -x "/opt/local/sbin/$name" ]]; then
    printf '%s\n' "/opt/local/sbin/$name"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  return 1
}

copy_binary() {
  local source="$1"
  local destination="$2"
  cp -fX "$source" "$destination"
  chmod +x "$destination"
  xattr -cr "$destination" 2>/dev/null || true
}

build_ntfs_populate_helper() {
  local source="$ROOT_DIR/script/helper_sources/ntfs-populate-helper.c"
  local output="$HELPER_DIR/ntfs-populate-helper"
  local include_dir="/opt/local/include/ntfs-3g"
  local lib_dir="/opt/local/lib"

  [[ -f "$source" ]] || return 0
  [[ -d "$include_dir" ]] || return 0
  [[ -d "$lib_dir" ]] || return 0

  /usr/bin/clang \
    -std=c11 \
    -O2 \
    -I"$include_dir" \
    -I"/opt/local/include" \
    -L"$lib_dir" \
    -lntfs-3g \
    "$source" \
    -o "$output"

  chmod +x "$output"
  xattr -cr "$output" 2>/dev/null || true
  collect_deps "$output"
}

build_freedos_boot_helper() {
  local source="$ROOT_DIR/script/helper_sources/freedos-boot-helper.c"
  local ms_sys_dir="$ROOT_DIR/script/helper_sources/ms-sys"
  local output="$HELPER_DIR/freedos-boot-helper"

  [[ -f "$source" ]] || return 0
  [[ -f "$ms_sys_dir/fat16.c" ]] || return 0
  [[ -f "$ms_sys_dir/fat32.c" ]] || return 0
  [[ -f "$ms_sys_dir/file.c" ]] || return 0

  /usr/bin/clang \
    -std=c11 \
    -O2 \
    -I"$ms_sys_dir/inc" \
    "$source" \
    "$ms_sys_dir/fat16.c" \
    "$ms_sys_dir/fat32.c" \
    "$ms_sys_dir/file.c" \
    -o "$output"

  chmod +x "$output"
  xattr -cr "$output" 2>/dev/null || true
}

collect_deps() {
  local target="$1"
  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    [[ "$dependency" != /opt/local/* ]] && continue
    [[ -f "$dependency" ]] || continue

    local base
    base="$(basename "$dependency")"
    if [[ ! -f "$LIB_DIR/$base" ]]; then
      copy_binary "$dependency" "$LIB_DIR/$base"
      collect_deps "$dependency"
    fi
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

rewrite_binary_links() {
  local target="$1"
  local mode="$2"

  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    [[ "$dependency" != /opt/local/* ]] && continue

    local base
    base="$(basename "$dependency")"
    if [[ -f "$LIB_DIR/$base" ]]; then
      local rewritten
      if [[ "$mode" == "executable" ]]; then
        rewritten="@executable_path/lib/$base"
      else
        rewritten="@loader_path/$base"
      fi
      install_name_tool -change "$dependency" "$rewritten" "$target"
    fi
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

for helper in "${HELPERS[@]}"; do
  if ! helper_path="$(resolve_helper "$helper")"; then
    continue
  fi

  copy_binary "$helper_path" "$HELPER_DIR/$helper"
  collect_deps "$helper_path"
done

build_ntfs_populate_helper
build_freedos_boot_helper

xattr -cr "$HELPER_DIR" "$LIB_DIR" 2>/dev/null || true

if compgen -G "$LIB_DIR/*" >/dev/null; then
  for library in "$LIB_DIR"/*; do
    base="$(basename "$library")"
    install_name_tool -id "@loader_path/$base" "$library"
  done

  for library in "$LIB_DIR"/*; do
    rewrite_binary_links "$library" "library"
  done
fi

for helper in "${HELPERS[@]}"; do
  if [[ -f "$HELPER_DIR/$helper" ]]; then
    rewrite_binary_links "$HELPER_DIR/$helper" "executable"
  fi
done

if [[ -f "$HELPER_DIR/ntfs-populate-helper" ]]; then
  rewrite_binary_links "$HELPER_DIR/ntfs-populate-helper" "executable"
fi

if [[ -f "$HELPER_DIR/freedos-boot-helper" ]]; then
  rewrite_binary_links "$HELPER_DIR/freedos-boot-helper" "executable"
fi

{
  if [[ -f "$HELPER_DIR/ntfs-populate-helper" ]]; then
    echo "ntfs-populate-helper"
  fi
  if [[ -f "$HELPER_DIR/freedos-boot-helper" ]]; then
    echo "freedos-boot-helper"
  fi
  for helper in "${HELPERS[@]}"; do
    if [[ -f "$HELPER_DIR/$helper" ]]; then
      echo "$helper"
    fi
  done
  if compgen -G "$LIB_DIR/*" >/dev/null; then
    find "$LIB_DIR" -type f -exec basename {} \; | sort | sed 's#^#lib/#'
  fi
} >"$MANIFEST"

rm -rf "$FINAL_HELPER_DIR"
mkdir -p "$(dirname "$FINAL_HELPER_DIR")"
/usr/bin/ditto "$HELPER_DIR" "$FINAL_HELPER_DIR"
xattr -cr "$FINAL_HELPER_DIR" 2>/dev/null || true
