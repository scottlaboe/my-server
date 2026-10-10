#!/usr/bin/env bash
# One-command setup for a fresh Ubuntu 24.04 (arm64 or amd64) server:
#
#   curl -fsSL https://raw.githubusercontent.com/scottlaboe/my-server/main/scripts/bootstrap.sh | sudo bash
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/scottlaboe/my-server.git}"
SITE_URL="${SITE_URL:-https://github.com/scottlaboe/scottlaboe.com.git}"
APP_DIR="${APP_DIR:-/opt/my-server}"
PORTFOLIO_DIR="${PORTFOLIO_DIR:-/srv/portfolio}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (use sudo)." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "==> Swap (${SWAP_SIZE})"
if ! swapon --show | grep -q .; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  sysctl -q -p /etc/sysctl.d/99-swappiness.conf
fi

echo "==> Packages"
apt-get update -qq
apt-get install -y -qq git curl unzip ca-certificates cron >/dev/null

echo "==> Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

echo "==> AWS CLI (for backups)"
if ! command -v aws >/dev/null; then
  arch="$(uname -m)"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscli.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  "$tmp/aws/install"
  rm -rf "$tmp"
fi

echo "==> Server repo -> $APP_DIR"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$APP_DIR"
fi

echo "==> Static site repo -> $PORTFOLIO_DIR"
mkdir -p "$(dirname "$PORTFOLIO_DIR")"
if [ -d "$PORTFOLIO_DIR/.git" ]; then
  git -C "$PORTFOLIO_DIR" pull --ff-only
else
  git clone "$SITE_URL" "$PORTFOLIO_DIR"
fi

echo "==> .env"
if [ ! -f "$APP_DIR/.env" ]; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
  sed -i "s|^WORDPRESS_DB_PASSWORD=.*|WORDPRESS_DB_PASSWORD=$(openssl rand -hex 24)|" "$APP_DIR/.env"
  sed -i "s|^MARIADB_ROOT_PASSWORD=.*|MARIADB_ROOT_PASSWORD=$(openssl rand -hex 24)|" "$APP_DIR/.env"
  sed -i "s|^PORTFOLIO_DIR=.*|PORTFOLIO_DIR=$PORTFOLIO_DIR|" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  echo "   generated new .env with random passwords"
fi

echo "==> Cron (portfolio sync every 5 min, backup check every 15 min)"
cat > /etc/cron.d/my-server <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * root git -C $PORTFOLIO_DIR pull --ff-only -q >> /var/log/my-server-sync.log 2>&1
*/15 * * * * root $APP_DIR/scripts/backup.sh >> /var/log/my-server-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/my-server

echo "==> Shared 'edge' network for separately-deployed apps"
docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null

echo "==> Start services"
cd "$APP_DIR"
docker compose up -d --remove-orphans

echo
echo "Done. Check status with:  cd $APP_DIR && docker compose ps"
