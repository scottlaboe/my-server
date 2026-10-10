#!/usr/bin/env bash
# One-time AWS setup, run from your own computer (not the server). Safe to re-run.
#
#   BUCKET=<backup-bucket> scripts/setup-aws.sh
#
#  - IAM user "server-admin" (policy "server-admin") for managing this server from the
#    CLI: EC2, the backup bucket, SSM /my-server/* and /house-hunter/*, the instance
#    role, and the DNS zone. Creating it needs broader credentials (e.g. an
#    AdministratorAccess user); its access keys go into the AWS CLI profile
#    "server-admin". Skipped if the user already exists.
#  - Instance role: lets the server read and save SSM /my-server/env.
set -euo pipefail

BUCKET="${BUCKET:?set BUCKET to the backup bucket name}"
DOMAIN="${DOMAIN:-scottlaboe.com}"
ROLE="${ROLE:-my-server-role}"
PROFILE_NAME="${PROFILE_NAME:-my-server-profile}"
ADMIN_USER="${ADMIN_USER:-server-admin}"

acct="$(aws sts get-caller-identity --query Account --output text)"
region="$(aws configure get region || true)"
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-${region:-us-east-1}}}"
export AWS_DEFAULT_REGION="$region"
zone="$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --max-items 1 \
        --query 'HostedZones[0].Id' --output text | sed 's|^/hostedzone/||')"
[ -n "$zone" ] && [ "$zone" != "None" ] || { echo "No Route 53 zone for $DOMAIN" >&2; exit 1; }

echo "==> IAM policy $ADMIN_USER"
policy_arn="arn:aws:iam::$acct:policy/$ADMIN_USER"
policy="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "EC2", "Effect": "Allow",
     "Action": ["ec2:*", "ec2-instance-connect:SendSSHPublicKey"], "Resource": "*"},
    {"Sid": "Metrics", "Effect": "Allow",
     "Action": ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics",
                "cloudwatch:DescribeAlarms", "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms"],
     "Resource": "*"},
    {"Sid": "BackupBucket", "Effect": "Allow", "Action": "s3:*",
     "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"]},
    {"Sid": "ListBuckets", "Effect": "Allow",
     "Action": ["s3:ListAllMyBuckets", "s3:GetBucketLocation"], "Resource": "*"},
    {"Sid": "ServerParams", "Effect": "Allow",
     "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory",
                "ssm:PutParameter", "ssm:DeleteParameter", "ssm:DeleteParameters", "ssm:LabelParameterVersion",
                "ssm:AddTagsToResource", "ssm:ListTagsForResource"],
     "Resource": ["arn:aws:ssm:$region:$acct:parameter/my-server/*",
                  "arn:aws:ssm:$region:$acct:parameter/house-hunter/*"]},
    {"Sid": "DescribeParams", "Effect": "Allow", "Action": "ssm:DescribeParameters", "Resource": "*"},
    {"Sid": "ServerRole", "Effect": "Allow",
     "Action": ["iam:GetRole", "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
                "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
                "iam:GetInstanceProfile"],
     "Resource": ["arn:aws:iam::$acct:role/$ROLE", "arn:aws:iam::$acct:instance-profile/$PROFILE_NAME"]},
    {"Sid": "PassServerRole", "Effect": "Allow", "Action": "iam:PassRole",
     "Resource": "arn:aws:iam::$acct:role/$ROLE",
     "Condition": {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}}},
    {"Sid": "IAMList", "Effect": "Allow",
     "Action": ["iam:ListRoles", "iam:ListInstanceProfiles"], "Resource": "*"},
    {"Sid": "DNS", "Effect": "Allow",
     "Action": ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets"],
     "Resource": "arn:aws:route53:::hostedzone/$zone"},
    {"Sid": "DNSRead", "Effect": "Allow",
     "Action": ["route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:GetChange"],
     "Resource": "*"}
  ]
}
JSON
)"
if aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
  # Managed policies keep at most 5 versions; drop the oldest non-default one first.
  old="$(aws iam list-policy-versions --policy-arn "$policy_arn" \
         --query 'Versions[?!IsDefaultVersion].VersionId' --output text | tr '\t' '\n' | sort -V)"
  if [ "$(printf '%s\n' "$old" | grep -c .)" -ge 4 ]; then
    aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$(printf '%s\n' "$old" | head -n1)"
  fi
  aws iam create-policy-version --policy-arn "$policy_arn" --policy-document "$policy" --set-as-default >/dev/null
  echo "   updated"
else
  aws iam create-policy --policy-name "$ADMIN_USER" --policy-document "$policy" \
    --description "Manage the $DOMAIN server: EC2, backups, SSM params, instance role, DNS" >/dev/null
  echo "   created"
fi

echo "==> IAM user $ADMIN_USER"
if aws iam get-user --user-name "$ADMIN_USER" >/dev/null 2>&1; then
  echo "   already exists"
else
  aws iam create-user --user-name "$ADMIN_USER" >/dev/null
  # Straight into the CLI config; the secret is never printed.
  aws iam create-access-key --user-name "$ADMIN_USER" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text |
    { read -r id secret
      aws configure set aws_access_key_id "$id" --profile "$ADMIN_USER"
      aws configure set aws_secret_access_key "$secret" --profile "$ADMIN_USER"
      aws configure set region "$region" --profile "$ADMIN_USER"; }
  echo "   created; access keys saved as AWS CLI profile \"$ADMIN_USER\""
fi
aws iam attach-user-policy --user-name "$ADMIN_USER" --policy-arn "$policy_arn"

echo "==> Instance role $ROLE: SSM /my-server/env"
aws iam put-role-policy --role-name "$ROLE" --policy-name my-server-ssm --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["ssm:GetParameter", "ssm:PutParameter"],
     "Resource": "arn:aws:ssm:$region:$acct:parameter/my-server/env"}
  ]
}
JSON
)"
echo "   ok"

echo
echo "Done. Use it with:  export AWS_PROFILE=$ADMIN_USER"
