#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGION="${REGION:-us-east-1}"
BACKEND_STACK="${BACKEND_STACK:-aws-springboot-backend}"
FRONTEND_STACK="${FRONTEND_STACK:-aws-springboot-frontend}"

echo "[infra:down] Checking AWS credentials..."
aws sts get-caller-identity >/dev/null 2>&1 || { echo "  Run: aws configure"; exit 1; }
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
BUILD_BUCKET="aws-springboot-build-${ACCOUNT_ID}-${REGION}"
SITE_BUCKET_NAME="${SITE_BUCKET_NAME:-aws-springboot-frontend-${ACCOUNT_ID}-${REGION}}"

echo "[infra:down] account: ${ACCOUNT_ID}  region: ${REGION}"
printf '\nThis will delete CloudFormation stacks (%s, %s),\nCodeBuild project, ECR repo, and S3 buckets.\n\n' \
  "${BACKEND_STACK}" "${FRONTEND_STACK}"
read -rp 'Proceed? (y/N): ' _ans
[[ "${_ans:-n}" =~ ^[Yy] ]] || { echo 'Aborted.'; exit 0; }

_delete_stack() {
  local stack="$1"
  if aws cloudformation describe-stacks --stack-name "${stack}" --region "${REGION}" >/dev/null 2>&1; then
    echo "[infra:down] deleting stack: ${stack}"
    aws cloudformation delete-stack --stack-name "${stack}" --region "${REGION}"
    aws cloudformation wait stack-delete-complete --stack-name "${stack}" --region "${REGION}"
    echo "[infra:down] deleted: ${stack}"
  else
    echo "[infra:down] stack not found, skipping: ${stack}"
  fi
}

_delete_stack "${FRONTEND_STACK}"
_delete_stack "${BACKEND_STACK}"

aws codebuild delete-project --name aws-springboot-image-build --region "${REGION}" >/dev/null 2>&1 || true
aws ecr delete-repository --repository-name aws-springboot-jobs --force --region "${REGION}" >/dev/null 2>&1 || true

for _bucket in "${BUILD_BUCKET}" "${SITE_BUCKET_NAME}"; do
  if aws s3api head-bucket --bucket "${_bucket}" >/dev/null 2>&1; then
    echo "[infra:down] emptying and deleting bucket: ${_bucket}"
    aws s3 rm "s3://${_bucket}" --recursive >/dev/null 2>&1 || true
    aws s3 rb "s3://${_bucket}" --force >/dev/null 2>&1 || true
  fi
done

echo "[infra:down] done"
