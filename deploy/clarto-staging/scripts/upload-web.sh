#!/usr/bin/env bash
# Uploads a commit of the CLARTO website repository (private, connected to
# Lovable) to the staging host for the preview, without giving the server
# access to the repository. Run it on a machine with a clone of the website.
#
#   scripts/upload-web.sh <path-to-website-clone> [ref] [ssh-target]
#   e.g. scripts/upload-web.sh ../../../web feat/catalogo-inmuebles ubuntu@57.129.192.99
#
# The exported tree lands in deploy/clarto-staging/src/web with .source-ref = commit SHA;
# then run scripts/deploy.sh --no-build=false (or scripts/compose.sh build web-preview && up -d).
set -euo pipefail
repo="${1:?usage: upload-web.sh <website-clone> [ref] [ssh-target]}"
ref="${2:-HEAD}"
target="${3:-ubuntu@57.129.192.99}"
remote_dir="${REMOTE_BUNDLE:-/srv/clarto-staging/pwb/deploy/clarto-staging}"

sha="$(git -C "$repo" rev-parse "$ref")"
tmp="$(mktemp)"
git -C "$repo" archive --format=tar.gz -o "$tmp" "$sha" -- . ':!docs'
scp -q "$tmp" "$target:/tmp/web-$sha.tgz"
ssh "$target" "set -e; rm -rf '$remote_dir/src/web.tmp'; mkdir -p '$remote_dir/src/web.tmp';
  tar -xzf /tmp/web-$sha.tgz -C '$remote_dir/src/web.tmp'; echo $sha > '$remote_dir/src/web.tmp/.source-ref';
  rm -rf '$remote_dir/src/web'; mv '$remote_dir/src/web.tmp' '$remote_dir/src/web'; rm -f /tmp/web-$sha.tgz"
rm -f "$tmp"
echo "uploaded website $sha ($ref) to $target:$remote_dir/src/web"
