#!/usr/bin/env bash
# Apply the latest repo changes (config, compose, image versions) and the latest static site.
# Also saves .env to SSM, so edit .env and then run this.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

git pull --ff-only
scripts/env-ssm.sh push || echo "warning: couldn't save .env to SSM" >&2
set -a; . ./.env; set +a
git -C "${PORTFOLIO_DIR:-/srv/portfolio}" pull --ff-only

docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f >/dev/null
docker compose ps
