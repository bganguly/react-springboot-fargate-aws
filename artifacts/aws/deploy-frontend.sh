#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <stack-name> <region> <site-bucket-name> <api-base-url> <frontend-dir>"
  echo "Example: $0 aws-springboot-frontend us-east-1 my-unique-site-bucket https://api.example.com frontend"
  exit 1
fi

STACK_NAME="$1"
REGION="$2"
SITE_BUCKET_NAME="$3"
API_BASE_URL="$4"
FRONTEND_DIR="$5"

aws cloudformation deploy \
  --template-file artifacts/aws/frontend-infra.yaml \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --parameter-overrides SiteBucketName="${SITE_BUCKET_NAME}"

DISTRIBUTION_ID="$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
  --output text)"

FRONTEND_URL="$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendUrl'].OutputValue" \
  --output text)"

ENV_FILE="${FRONTEND_DIR}/.env.production.local"
trap 'rm -f "${ENV_FILE}"' EXIT

echo "VITE_API_BASE_URL=${API_BASE_URL}" > "${ENV_FILE}"

npm --prefix "${FRONTEND_DIR}" install
npm --prefix "${FRONTEND_DIR}" run build

aws s3 sync "${FRONTEND_DIR}/dist" "s3://${SITE_BUCKET_NAME}" --delete --region "${REGION}"
aws cloudfront create-invalidation --distribution-id "${DISTRIBUTION_ID}" --paths "/*" >/dev/null

echo "Frontend deployed: ${FRONTEND_URL}"
