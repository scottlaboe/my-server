#!/usr/bin/env bash
# Keep .env in SSM Parameter Store (SecureString, default aws/ssm key) so a fresh
# server comes up with the same secrets. The instance's IAM role grants access.
#
#   scripts/env-ssm.sh pull   # write .env from SSM if .env is missing (exit 3 if SSM has none)
#   scripts/env-ssm.sh push   # save .env to SSM if it differs from what's stored
#
# SSM keeps the last 100 versions, so an unwanted push can be undone with
#   aws ssm get-parameter-history --name /my-server/env --with-decryption
set -euo pipefail

PARAM="${ENV_PARAM:-/my-server/env}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$APP_DIR/.env"

# SSM calls need a region; on EC2, take it from instance metadata.
if [ -z "${AWS_REGION:-}${AWS_DEFAULT_REGION:-}" ]; then
  tok="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" || tok=""
  region="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)" || region=""
  [ -z "$region" ] || export AWS_DEFAULT_REGION="$region"
fi

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
stored() { aws ssm get-parameter --name "$PARAM" --with-decryption --query Parameter.Value --output text 2>"$err"; }

case "${1:-}" in
  pull)
    [ ! -f "$ENV_FILE" ] || { echo "   .env already exists; not overwriting"; exit 0; }
    if value="$(stored)"; then
      (umask 077; printf '%s\n' "$value" > "$ENV_FILE")
      echo "   restored .env from SSM $PARAM"
    elif grep -q ParameterNotFound "$err"; then
      exit 3
    else
      cat "$err" >&2
      exit 1
    fi
    ;;
  push)
    [ -f "$ENV_FILE" ] || { echo "no .env to push" >&2; exit 1; }
    if value="$(stored)" && [ "$value" = "$(cat "$ENV_FILE")" ]; then
      exit 0
    fi
    grep -q ParameterNotFound "$err" || [ ! -s "$err" ] || { cat "$err" >&2; exit 1; }
    aws ssm put-parameter --name "$PARAM" --type SecureString --overwrite \
      --value "file://$ENV_FILE" >/dev/null
    echo "   saved .env to SSM $PARAM"
    ;;
  *)
    echo "usage: $0 pull|push" >&2
    exit 2
    ;;
esac
