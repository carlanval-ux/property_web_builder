#!/usr/bin/env bash
# One-time preparation of a fresh Ubuntu 24.04 LTS host for CLARTO staging.
# Run as root (sudo). Idempotent.
#
#   sudo deploy/clarto-staging/scripts/install-host.sh <deploy-user>
#
# - Docker Engine + compose plugin from Docker's official apt repository
# - log rotation for containers, unattended security upgrades
# - ufw: only SSH, HTTP, HTTPS
# - /srv/clarto-staging/backups (root-only) and a daily backup timer
set -euo pipefail

DEPLOY_USER="${1:?usage: install-host.sh <deploy-user>}"
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

. /etc/os-release
[ "$ID" = ubuntu ] || { echo "Ubuntu expected, found $ID" >&2; exit 1; }
[ "$VERSION_ID" = "24.04" ] || echo "WARNING: tested on Ubuntu 24.04 LTS, this host is $PRETTY_NAME" >&2

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq ca-certificates curl gnupg git ufw unattended-upgrades python3 openssl

if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
EOF
  systemctl restart docker
fi
usermod -aG docker "$DEPLOY_USER"

dpkg-reconfigure -f noninteractive unattended-upgrades

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

install -d -m 0700 -o root -g root /srv/clarto-staging/backups

cat > /etc/systemd/system/clarto-backup.service <<EOF
[Unit]
Description=CLARTO staging backup (databases + photo volumes)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=BACKUP_ROOT=/srv/clarto-staging/backups
ExecStart=${BUNDLE_DIR}/scripts/backup.sh
EOF

cat > /etc/systemd/system/clarto-backup.timer <<'EOF'
[Unit]
Description=Daily CLARTO staging backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now clarto-backup.timer

docker --version
docker compose version
echo "host ready — log out and back in as $DEPLOY_USER so the docker group applies"
