#!/usr/bin/env bash
# One-command setup for a fresh Ubuntu 24.04 (arm64 or amd64) server:
#
#   curl -fsSL https://raw.githubusercontent.com/scottlaboe/my-server/main/scripts/bootstrap.sh | sudo bash
#
# On a fresh server it also restores .env from SSM and the newest WordPress backup from
# S3, then installs house-hunter (a private repo, cloned with a deploy key from SSM).
# Needs the instance profile my-server-profile; run scripts/setup-aws.sh once first.
#
# Safe to re-run: every step is idempotent, and nothing is restored over existing data.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/scottlaboe/my-server.git}"
BRANCH="${BRANCH:-main}"
SITE_URL="${SITE_URL:-https://github.com/scottlaboe/scottlaboe.com.git}"
APP_DIR="${APP_DIR:-/opt/my-server}"
PORTFOLIO_DIR="${PORTFOLIO_DIR:-/srv/portfolio}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
HH_REPO_URL="${HH_REPO_URL:-git@github.com:scottlaboe/house-hunter.git}"
HH_BRANCH="${HH_BRANCH:-main}"
HH_DIR="${HH_DIR:-/opt/house-hunter}"
HH_KEY_PARAM="${HH_KEY_PARAM:-/house-hunter/deploy-key}"
# github.com's published SSH host key (gh api meta), pinned so the clone can't be intercepted
GITHUB_HOST_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

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
# SSM calls need a region; take it from instance metadata.
if [ -z "${AWS_REGION:-}${AWS_DEFAULT_REGION:-}" ]; then
  tok="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" || tok=""
  region="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)" || region=""
  [ -z "$region" ] || export AWS_DEFAULT_REGION="$region"
fi

echo "==> Server repo -> $APP_DIR"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
else
  git clone -b "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

echo "==> Static site repo -> $PORTFOLIO_DIR"
mkdir -p "$(dirname "$PORTFOLIO_DIR")"
if [ -d "$PORTFOLIO_DIR/.git" ]; then
  git -C "$PORTFOLIO_DIR" pull --ff-only
else
  git clone "$SITE_URL" "$PORTFOLIO_DIR"
fi

echo "==> .env (kept in SSM /my-server/env)"
if [ ! -f "$APP_DIR/.env" ] && ! "$APP_DIR/scripts/env-ssm.sh" pull; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
  sed -i "s|^WORDPRESS_DB_PASSWORD=.*|WORDPRESS_DB_PASSWORD=$(openssl rand -hex 24)|" "$APP_DIR/.env"
  sed -i "s|^MARIADB_ROOT_PASSWORD=.*|MARIADB_ROOT_PASSWORD=$(openssl rand -hex 24)|" "$APP_DIR/.env"
  sed -i "s|^PORTFOLIO_DIR=.*|PORTFOLIO_DIR=$PORTFOLIO_DIR|" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  echo "   generated new .env with random passwords; set BACKUP_BUCKET in it, then run scripts/deploy.sh"
fi
"$APP_DIR/scripts/env-ssm.sh" push || echo "   warning: couldn't save .env to SSM (see above)"

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

echo "==> WordPress data"
# The wordpress container fills the volume (including wp-config.php) on first start.
for _ in $(seq 60); do
  docker compose exec -T wordpress test -f /var/www/html/wp-config.php 2>/dev/null && break
  sleep 2
done
# Fails (and stops the script) if the database can't be queried, so an existing
# site is never mistaken for an empty one.
tables="$(docker compose exec -T db sh -c 'mariadb -N -uroot -p"$MARIADB_ROOT_PASSWORD" wordpress -e "SHOW TABLES LIKE \"wp_options\""')"
if [ -n "$tables" ]; then
  echo "   database present"
else
  rc=0
  scripts/restore.sh --latest || rc=$?
  case "$rc" in
    0) ;;
    3) echo "   no backup to restore; finish WordPress setup in the browser" ;;
    *) echo "WordPress restore failed." >&2; exit 1 ;;
  esac
fi

echo "==> house-hunter (private repo, deploy key from SSM $HH_KEY_PARAM)"
if key="$(aws ssm get-parameter --name "$HH_KEY_PARAM" --with-decryption --query Parameter.Value --output text 2>/dev/null)"; then
  install -d -m 700 /root/.ssh
  (umask 077; printf '%s\n' "$key" > /root/.ssh/house-hunter-deploy)
  grep -qsxF "github.com $GITHUB_HOST_KEY" /root/.ssh/known_hosts || echo "github.com $GITHUB_HOST_KEY" >> /root/.ssh/known_hosts
  ssh_cmd="ssh -i /root/.ssh/house-hunter-deploy -o IdentitiesOnly=yes"
  if [ ! -d "$HH_DIR/.git" ]; then
    GIT_SSH_COMMAND="$ssh_cmd" git clone -b "$HH_BRANCH" "$HH_REPO_URL" "$HH_DIR"
  fi
  # Later pulls (install.sh, deploy.sh) use the same key.
  git -C "$HH_DIR" config core.sshCommand "$ssh_cmd"
  "$HH_DIR/scripts/install.sh"
else
  echo "   deploy key not readable from SSM; skipping (run house-hunter's scripts/setup-aws.sh)"
fi

echo
echo "Done. Check status with:  cd $APP_DIR && docker compose ps"
