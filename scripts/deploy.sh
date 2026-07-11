#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGION="${REGION:-us-east-1}"
BACKEND_STACK="${BACKEND_STACK:-aws-springboot-backend}"
FRONTEND_STACK="${FRONTEND_STACK:-aws-springboot-frontend}"

_require() {
  local var="$1" prompt="$2" val
  if [[ -z "${!var:-}" ]]; then
    read -rp "  ${prompt}: " val
    [[ -z "${val}" ]] && { echo "Error: ${var} is required."; exit 1; }
    printf -v "$var" '%s' "$val"
  fi
}

echo "[deploy] Checking AWS credentials..."
aws sts get-caller-identity >/dev/null 2>&1 || { echo "  Run: aws configure"; exit 1; }
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
BUILD_BUCKET="aws-springboot-build-${ACCOUNT_ID}-${REGION}"
SITE_BUCKET_NAME="${SITE_BUCKET_NAME:-aws-springboot-frontend-${ACCOUNT_ID}-${REGION}}"
SOURCE_KEY="source/aws-springboot-src.zip"
CODEBUILD_ROLE_NAME="aws-springboot-codebuild-role"
CODEBUILD_PROJECT_NAME="aws-springboot-image-build"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/aws-springboot-jobs:latest"
SOURCE_URI="${BUILD_BUCKET}/${SOURCE_KEY}"

echo "[deploy] account: ${ACCOUNT_ID}  region: ${REGION}"
echo "[deploy] backend stack: ${BACKEND_STACK}  frontend stack: ${FRONTEND_STACK}"

_require VPC_ID   "VPC ID (vpc-...)"
_require SUBNET_A "Public subnet A (subnet-...)"
_require SUBNET_B "Public subnet B (subnet-...)"

# ── ECR ───────────────────────────────────────────────────────────────────────
aws ecr describe-repositories --repository-names aws-springboot-jobs --region "${REGION}" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name aws-springboot-jobs --region "${REGION}" >/dev/null

# ── S3 build bucket ───────────────────────────────────────────────────────────
if ! aws s3api head-bucket --bucket "${BUILD_BUCKET}" >/dev/null 2>&1; then
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3 mb "s3://${BUILD_BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${BUILD_BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
fi

# ── CodeBuild IAM role ────────────────────────────────────────────────────────
if ! aws iam get-role --role-name "${CODEBUILD_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${CODEBUILD_ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    >/dev/null
fi
aws iam put-role-policy --role-name "${CODEBUILD_ROLE_NAME}" \
  --policy-name aws-springboot-codebuild-inline \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","s3:GetObject","s3:PutObject","s3:GetObjectVersion","s3:ListBucket","ecr:GetAuthorizationToken","ecr:BatchCheckLayerAvailability","ecr:CompleteLayerUpload","ecr:InitiateLayerUpload","ecr:PutImage","ecr:UploadLayerPart","ecr:BatchGetImage"],"Resource":"*"}]}' \
  >/dev/null

# ── CodeBuild project ─────────────────────────────────────────────────────────
if ! aws codebuild batch-get-projects --names "${CODEBUILD_PROJECT_NAME}" --region "${REGION}" \
     --query 'projects[0].name' --output text 2>/dev/null | grep -q "${CODEBUILD_PROJECT_NAME}"; then
  aws codebuild create-project --name "${CODEBUILD_PROJECT_NAME}" --region "${REGION}" \
    --source type=S3,location="${SOURCE_URI}",buildspec=buildspec.yml \
    --artifacts type=NO_ARTIFACTS \
    --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
    --service-role "arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}" >/dev/null
else
  aws codebuild update-project --name "${CODEBUILD_PROJECT_NAME}" --region "${REGION}" \
    --source type=S3,location="${SOURCE_URI}",buildspec=buildspec.yml \
    --artifacts type=NO_ARTIFACTS \
    --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
    --service-role "arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}" >/dev/null
fi

# ── Package and upload source ─────────────────────────────────────────────────
cd "${ROOT_DIR}"
[[ -f buildspec.yml ]] || { echo "Error: buildspec.yml not found at repo root."; exit 1; }
/usr/bin/zip -r /tmp/aws-springboot-src.zip . -x "frontend/node_modules/*" "frontend/dist/*" ".git/*" >/dev/null
aws s3 cp /tmp/aws-springboot-src.zip "s3://${BUILD_BUCKET}/${SOURCE_KEY}" --region "${REGION}" >/dev/null

# ── CodeBuild: build Docker image ─────────────────────────────────────────────
BUILD_ID="$(aws codebuild start-build --project-name "${CODEBUILD_PROJECT_NAME}" --region "${REGION}" --query 'build.id' --output text)"
echo "[deploy] CodeBuild started: ${BUILD_ID}"

while true; do
  BUILD_STATUS="$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${REGION}" --query 'builds[0].buildStatus' --output text)"
  echo "[deploy] CodeBuild: ${BUILD_STATUS}"
  [[ "${BUILD_STATUS}" == "SUCCEEDED" ]] && break
  if [[ "${BUILD_STATUS}" == "FAILED" || "${BUILD_STATUS}" == "FAULT" || "${BUILD_STATUS}" == "TIMED_OUT" || "${BUILD_STATUS}" == "STOPPED" ]]; then
    echo "[deploy] CodeBuild failed."; exit 1
  fi
  sleep 5
done

# ── Backend CloudFormation stack ──────────────────────────────────────────────
aws cloudformation deploy \
  --template-file "${ROOT_DIR}/artifacts/aws/infra.yaml" \
  --stack-name "${BACKEND_STACK}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "${REGION}" \
  --parameter-overrides VpcId="${VPC_ID}" PublicSubnetA="${SUBNET_A}" PublicSubnetB="${SUBNET_B}" ContainerImage="${IMAGE_URI}"

API_HTTPS_URL="$(aws cloudformation describe-stacks \
  --region "${REGION}" --stack-name "${BACKEND_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiHttpsUrl'].OutputValue" --output text)"
echo "[deploy] Backend live: ${API_HTTPS_URL}"

# ── Frontend CloudFormation stack ─────────────────────────────────────────────
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

# ── Build and sync frontend ───────────────────────────────────────────────────
ENV_FILE="${ROOT_DIR}/frontend/.env.production.local"
trap 'rm -f "${ENV_FILE}"' EXIT
echo "VITE_API_BASE_URL=${API_HTTPS_URL}" > "${ENV_FILE}"
npm --prefix "${ROOT_DIR}/frontend" install
npm --prefix "${ROOT_DIR}/frontend" run build
aws s3 sync "${ROOT_DIR}/frontend/dist" "s3://${SITE_BUCKET_NAME}" --delete --region "${REGION}"
aws cloudfront create-invalidation --distribution-id "${DISTRIBUTION_ID}" --paths "/*" >/dev/null

echo ""
echo "[deploy] Done."
echo "  API:      ${API_HTTPS_URL}"
echo "  Frontend: ${FRONTEND_URL}"
