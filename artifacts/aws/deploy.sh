#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 6 ]]; then
  echo "Usage: $0 <stack-name> <region> <account-id> <vpc-id> <subnet-a> <subnet-b>"
  exit 1
fi

STACK_NAME="$1"
REGION="$2"
ACCOUNT_ID="$3"
VPC_ID="$4"
SUBNET_A="$5"
SUBNET_B="$6"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_BUCKET="aws-springboot-build-${ACCOUNT_ID}-${REGION}"
SOURCE_KEY="source/aws-springboot-src.zip"
SOURCE_URI="${BUILD_BUCKET}/${SOURCE_KEY}"
CODEBUILD_ROLE_NAME="aws-springboot-codebuild-role"
CODEBUILD_PROJECT_NAME="aws-springboot-image-build"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/aws-springboot-jobs:latest"

aws ecr describe-repositories --repository-names aws-springboot-jobs --region "${REGION}" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name aws-springboot-jobs --region "${REGION}" >/dev/null

if ! aws s3api head-bucket --bucket "${BUILD_BUCKET}" >/dev/null 2>&1; then
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3 mb "s3://${BUILD_BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${BUILD_BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
fi

if ! aws iam get-role --role-name "${CODEBUILD_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "${CODEBUILD_ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    >/dev/null
fi

aws iam put-role-policy \
  --role-name "${CODEBUILD_ROLE_NAME}" \
  --policy-name aws-springboot-codebuild-inline \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","s3:GetObject","s3:PutObject","s3:GetObjectVersion","s3:ListBucket","ecr:GetAuthorizationToken","ecr:BatchCheckLayerAvailability","ecr:CompleteLayerUpload","ecr:InitiateLayerUpload","ecr:PutImage","ecr:UploadLayerPart","ecr:BatchGetImage"],"Resource":"*"}]}' \
  >/dev/null

if ! aws codebuild batch-get-projects --names "${CODEBUILD_PROJECT_NAME}" --region "${REGION}" --query 'projects[0].name' --output text | grep -q "${CODEBUILD_PROJECT_NAME}"; then
  aws codebuild create-project \
    --name "${CODEBUILD_PROJECT_NAME}" \
    --region "${REGION}" \
    --source type=S3,location="${SOURCE_URI}",buildspec=buildspec.yml \
    --artifacts type=NO_ARTIFACTS \
    --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
    --service-role "arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}" \
    >/dev/null
else
  aws codebuild update-project \
    --name "${CODEBUILD_PROJECT_NAME}" \
    --region "${REGION}" \
    --source type=S3,location="${SOURCE_URI}",buildspec=buildspec.yml \
    --artifacts type=NO_ARTIFACTS \
    --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
    --service-role "arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}" \
    >/dev/null
fi

cd "${REPO_ROOT}"
if [[ ! -f buildspec.yml ]]; then
  echo "Error: buildspec.yml not found at repo root."
  exit 1
fi

/usr/bin/zip -r /tmp/aws-springboot-src.zip . -x "frontend/node_modules/*" "frontend/dist/*" ".git/*" >/dev/null
aws s3 cp /tmp/aws-springboot-src.zip "s3://${BUILD_BUCKET}/${SOURCE_KEY}" --region "${REGION}" >/dev/null

BUILD_ID="$(aws codebuild start-build --project-name "${CODEBUILD_PROJECT_NAME}" --region "${REGION}" --query 'build.id' --output text)"
echo "Started CodeBuild: ${BUILD_ID}"

while true; do
  BUILD_STATUS="$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${REGION}" --query 'builds[0].buildStatus' --output text)"
  echo "CodeBuild status: ${BUILD_STATUS}"
  if [[ "${BUILD_STATUS}" == "SUCCEEDED" ]]; then
    break
  fi
  if [[ "${BUILD_STATUS}" == "FAILED" || "${BUILD_STATUS}" == "FAULT" || "${BUILD_STATUS}" == "TIMED_OUT" || "${BUILD_STATUS}" == "STOPPED" ]]; then
    echo "CodeBuild did not succeed."
    exit 1
  fi
  sleep 5
done

aws cloudformation deploy \
  --template-file "${REPO_ROOT}/artifacts/aws/infra.yaml" \
  --stack-name "${STACK_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "${REGION}" \
  --parameter-overrides \
    VpcId="${VPC_ID}" \
    PublicSubnetA="${SUBNET_A}" \
    PublicSubnetB="${SUBNET_B}" \
    ContainerImage="${IMAGE_URI}"

API_BASE_URL="$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiBaseUrl'].OutputValue" \
  --output text)"

echo "Backend deployment complete. API base URL: ${API_BASE_URL}"
