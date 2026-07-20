#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGION="${REGION:-us-east-1}"
BACKEND_STACK="${BACKEND_STACK:-aws-springboot-backend}"
FRONTEND_STACK="${FRONTEND_STACK:-aws-springboot-frontend}"
ECR_REPO="aws-springboot-jobs"

echo "[1/5] Checking AWS credentials..."
aws sts get-caller-identity >/dev/null 2>&1 || { echo "  Run: aws configure"; exit 1; }
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
printf '  Credentials valid: %s\n' "$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"

_GH_REPO="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null \
  | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|; s|.*github\.com[:/]\(.*\)$|\1|')"
if command -v gh >/dev/null 2>&1 && [[ -n "$_GH_REPO" ]]; then
  printf '  Syncing AWS credentials to GitHub Actions secrets (%s)...\n' "$_GH_REPO"
  aws configure get aws_access_key_id     | gh secret set AWS_ACCESS_KEY_ID     --repo "$_GH_REPO"
  aws configure get aws_secret_access_key | gh secret set AWS_SECRET_ACCESS_KEY --repo "$_GH_REPO"
  printf '%s' "$REGION"                   | gh secret set AWS_REGION            --repo "$_GH_REPO"
fi

SITE_BUCKET_NAME="${SITE_BUCKET_NAME:-aws-springboot-frontend-${ACCOUNT_ID}-${REGION}}"

if [[ -z "${VPC_ID:-}" ]]; then
  VPC_ID="$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null)"
  [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && { echo "Error: no default VPC found. Set VPC_ID manually."; exit 1; }
  printf '  Auto-detected VPC: %s\n' "$VPC_ID"
fi

if [[ -z "${SUBNET_A:-}" || -z "${SUBNET_B:-}" ]]; then
  mapfile -t _SUBNETS < <(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[*].SubnetId' --output text --region "$REGION" 2>/dev/null | tr '\t' '\n')
  [[ ${#_SUBNETS[@]} -lt 2 ]] && { echo "Error: need at least 2 public subnets in $VPC_ID."; exit 1; }
  SUBNET_A="${_SUBNETS[0]}"
  SUBNET_B="${_SUBNETS[1]}"
  printf '  Auto-detected subnets: %s, %s\n' "$SUBNET_A" "$SUBNET_B"
fi

echo ""
echo "[2/5] Provisioning ECR repository..."
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" >/dev/null
printf '  ECR repo ready.\n'

echo ""
echo "[3/5] Verifying ECR image..."
_REMOTE_SHA="$(git -C "$ROOT_DIR" ls-remote origin HEAD 2>/dev/null | cut -c1-7)"
_DEPLOY_TAG="${_REMOTE_SHA:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "latest")}"

_ecr_image_exists() {
  aws ecr describe-images \
    --repository-name "$ECR_REPO" \
    --image-ids "imageTag=$1" \
    --region "$REGION" >/dev/null 2>&1
}

printf '  Checking ECR for image %s...\n' "$_DEPLOY_TAG"
if ! _ecr_image_exists "$_DEPLOY_TAG"; then
  if _ecr_image_exists "latest"; then
    printf '  SHA %s not in ECR (image unchanged) — using latest.\n' "$_DEPLOY_TAG"
    _DEPLOY_TAG=latest
  else
    printf '  No image in ECR yet — waiting for GitHub Actions build (up to 10 min)...\n'
    _ecr_elapsed=0
    until _ecr_image_exists "latest"; do
      if (( _ecr_elapsed >= 600 )); then
        printf '  Timed out. Check Actions: https://github.com/%s/actions\n' "$_GH_REPO"
        exit 1
      fi
      sleep 15; _ecr_elapsed=$(( _ecr_elapsed + 15 ))
      printf '  ...%ds\n' "$_ecr_elapsed"
    done
    _DEPLOY_TAG=latest
  fi
fi
printf '  Image %s found in ECR.\n' "$_DEPLOY_TAG"

IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:${_DEPLOY_TAG}"

echo ""
echo "[4/5] Deploying backend (CloudFormation)..."
aws cloudformation deploy \
  --template-file "${ROOT_DIR}/artifacts/aws/infra.yaml" \
  --stack-name "${BACKEND_STACK}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "${REGION}" \
  --parameter-overrides VpcId="${VPC_ID}" PublicSubnetA="${SUBNET_A}" PublicSubnetB="${SUBNET_B}" ContainerImage="${IMAGE_URI}"

API_HTTPS_URL="$(aws cloudformation describe-stacks \
  --region "${REGION}" --stack-name "${BACKEND_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiHttpsUrl'].OutputValue" --output text)"
printf '  Backend live: %s\n' "$API_HTTPS_URL"

echo ""
echo "[5/5] Deploying frontend (CloudFormation + S3 sync)..."
aws cloudformation deploy \
  --template-file "${ROOT_DIR}/artifacts/aws/frontend-infra.yaml" \
  --stack-name "${FRONTEND_STACK}" \
  --region "${REGION}" \
  --parameter-overrides SiteBucketName="${SITE_BUCKET_NAME}"

DISTRIBUTION_ID="$(aws cloudformation describe-stacks \
  --region "${REGION}" --stack-name "${FRONTEND_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" --output text)"

FRONTEND_URL="$(aws cloudformation describe-stacks \
  --region "${REGION}" --stack-name "${FRONTEND_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendUrl'].OutputValue" --output text)"

ENV_FILE="${ROOT_DIR}/frontend/.env.production.local"
trap 'rm -f "${ENV_FILE}"' EXIT
echo "VITE_API_BASE_URL=${API_HTTPS_URL}" > "${ENV_FILE}"
npm --prefix "${ROOT_DIR}/frontend" install
npm --prefix "${ROOT_DIR}/frontend" run build
aws s3 sync "${ROOT_DIR}/frontend/dist" "s3://${SITE_BUCKET_NAME}" --delete --region "${REGION}"
aws cloudfront create-invalidation --distribution-id "${DISTRIBUTION_ID}" --paths "/*" >/dev/null

PORTFOLIO_SET_LIVE="$(cd "$ROOT_DIR/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
if [[ -n "${FRONTEND_URL:-}" && -f "$PORTFOLIO_SET_LIVE" ]]; then
  bash "$PORTFOLIO_SET_LIVE" fargate "${FRONTEND_URL}" "${API_HTTPS_URL}"
fi

echo ""
echo "[deploy] Done."
printf '  API:      %s\n' "$API_HTTPS_URL"
printf '  Frontend: %s\n' "$FRONTEND_URL"
