#!/usr/bin/env bash
# Exports the pinned Liberu commit into src/liberu (no .git, reproducible).
source "$(dirname "$0")/lib.sh"

cache="$BUNDLE_DIR/src/.liberu.git"
target="$BUNDLE_DIR/src/liberu"

if [ -f "$target/.source-ref" ] && [ "$(cat "$target/.source-ref")" = "$LIBERU_REF" ]; then
  log "src/liberu already at ${LIBERU_REF}"
  exit 0
fi

mkdir -p "$BUNDLE_DIR/src"
[ -d "$cache" ] || git init -q --bare "$cache"
git -C "$cache" fetch -q --depth 1 "$LIBERU_REPO" "$LIBERU_REF"
rm -rf "$target.tmp" && mkdir -p "$target.tmp"
git -C "$cache" archive "$LIBERU_REF" | tar -x -C "$target.tmp"
echo "$LIBERU_REF" > "$target.tmp/.source-ref"
rm -rf "$target" && mv "$target.tmp" "$target"
log "src/liberu exported at ${LIBERU_REF}"
