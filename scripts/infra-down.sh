#!/usr/bin/env bash
# infra-down.sh — stop local dev or tear down AWS ECS Fargate stack
# Usage: ./scripts/infra-down.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${REGION:-us-east-1}"
BACKEND_STACK="${BACKEND_STACK:-aws-springboot-backend}"
FRONTEND_STACK="${FRONTEND_STACK:-aws-springboot-frontend}"
ECS_CLUSTER="aws-springboot-jobs"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

_local_running=0
lsof -ti:8080 >/dev/null 2>&1 && _local_running=1 || true
_aws_deployed=0
aws cloudformation describe-stacks --stack-name "$BACKEND_STACK" --region "$REGION" \
  >/dev/null 2>&1 && _aws_deployed=1 || true

printf '\n=== react-springboot-fargate-aws teardown ===\n\n'
printf '  [1] Local  — stop local backend (port 8080)'
(( _local_running )) && printf ' [running]' || printf ' [not detected]'
printf '\n'
printf '  [2] Cloud  — destroy AWS ECS Fargate + CloudFormation stacks'
(( _aws_deployed )) && printf ' [deployed]' || printf ' [not deployed]'
printf '\n'
printf '\nChoice [1/2, default 2]: '
read -r _MODE
case "$_MODE" in
  1) _TARGET="local" ;;
  *) _TARGET="cloud" ;;
esac

# ── local ─────────────────────────────────────────────────────────────────────
if [[ "$_TARGET" == "local" ]]; then
  _pid="$(lsof -ti:8080 2>/dev/null || true)"
  if [[ -n "$_pid" ]]; then
    kill "$_pid" 2>/dev/null && green '  Stopped backend on :8080'
  else
    dim '  No process found on :8080.'
  fi
  green 'Done.'
  exit 0
fi

# ── cloud: detect ECS state ───────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || { red 'aws CLI not found'; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { red 'AWS credentials not configured — run: aws configure'; exit 1; }
dim "  Credentials: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

_ECS_SVC=$(aws ecs list-services --cluster "$ECS_CLUSTER" --region "$REGION" \
  --query 'serviceArns[0]' --output text 2>/dev/null || true)
_ECS_COUNT=""
if [[ -n "$_ECS_SVC" && "$_ECS_SVC" != "None" ]]; then
  _ECS_COUNT=$(aws ecs describe-services --cluster "$ECS_CLUSTER" \
    --services "$_ECS_SVC" --region "$REGION" \
    --query 'services[0].desiredCount' --output text 2>/dev/null || true)
fi
printf '\n  ECS cluster: %s  desired-count: %s\n' "$ECS_CLUSTER" "${_ECS_COUNT:-unknown}"
printf '  [1] Start now  [2] Stop now  [3] Suspend schedule  [4] Resume schedule  [enter] Tear down: '
read -r _PRE_ACTION

case "${_PRE_ACTION:-}" in
  1)
    [[ -z "$_ECS_SVC" || "$_ECS_SVC" == "None" ]] && { red '  ECS service not found.'; exit 1; }
    aws ecs update-service --cluster "$ECS_CLUSTER" --service "$_ECS_SVC" \
      --desired-count 1 --region "$REGION" --no-cli-pager >/dev/null \
      && green '  ECS service started — desired-count set to 1.' \
      || red '  Failed to start ECS service.'
    exit 0
    ;;
  2)
    [[ -z "$_ECS_SVC" || "$_ECS_SVC" == "None" ]] && { red '  ECS service not found.'; exit 1; }
    aws ecs update-service --cluster "$ECS_CLUSTER" --service "$_ECS_SVC" \
      --desired-count 0 --region "$REGION" --no-cli-pager >/dev/null \
      && green '  ECS service stopped — desired-count set to 0.' \
      || red '  Failed to stop ECS service.'
    exit 0
    ;;
  3|4)
    dim '  No scheduler configured for this project.'
    exit 0
    ;;
esac

# ── tear down ─────────────────────────────────────────────────────────────────
BUILD_BUCKET="aws-springboot-build-${ACCOUNT_ID}-${REGION}"
SITE_BUCKET="aws-springboot-frontend-${ACCOUNT_ID}-${REGION}"

printf '\n  This will destroy:\n'
printf '    CloudFormation stacks: %s, %s\n' "$BACKEND_STACK" "$FRONTEND_STACK"
printf '    ECR repository: aws-springboot-jobs\n'
printf '    CodeBuild project\n'
printf '    S3 buckets: %s, %s\n' "$BUILD_BUCKET" "$SITE_BUCKET"
printf '\n  Proceed? [Y/n]: '
read -r _CONFIRM
[[ "${_CONFIRM:-y}" =~ ^[Yy]$ ]] || { red 'Aborted.'; exit 1; }

if [[ -n "$_ECS_SVC" && "$_ECS_SVC" != "None" && "${_ECS_COUNT:-0}" != "0" ]]; then
  bold 'Scaling ECS to 0 before destroy...'
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "$_ECS_SVC" \
    --desired-count 0 --region "$REGION" --no-cli-pager >/dev/null 2>/dev/null || true
  green '  ECS desired-count set to 0'
fi

_delete_stack() {
  local stack="$1"
  if aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" >/dev/null 2>&1; then
    bold "Deleting stack: $stack"
    aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION"
    green "  $stack deleted"
  else
    dim "  Stack not found, skipping: $stack"
  fi
}

_delete_stack "$FRONTEND_STACK"
_delete_stack "$BACKEND_STACK"

bold 'Cleaning up ECR and CodeBuild...'
aws ecr delete-repository --repository-name aws-springboot-jobs --force --region "$REGION" \
  >/dev/null 2>/dev/null && green '  ECR repository deleted' || dim '  ECR not found'
aws codebuild delete-project --name aws-springboot-image-build --region "$REGION" \
  >/dev/null 2>/dev/null && green '  CodeBuild project deleted' || dim '  CodeBuild not found'

bold 'Emptying and deleting S3 buckets...'
for _bucket in "$BUILD_BUCKET" "$SITE_BUCKET"; do
  if aws s3api head-bucket --bucket "$_bucket" >/dev/null 2>&1; then
    aws s3 rm "s3://${_bucket}" --recursive >/dev/null 2>/dev/null || true
    aws s3 rb "s3://${_bucket}" --force >/dev/null 2>/dev/null \
      && green "  $bucket deleted" || dim "  $bucket delete skipped"
  else
    dim "  $bucket not found"
  fi
done

green '\nAWS infrastructure torn down.'
printf '  Redeploy: ./scripts/deploy.sh\n'
