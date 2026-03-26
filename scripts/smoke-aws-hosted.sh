#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <api-base-url> <frontend-url>"
  echo "Example: $0 http://my-api-alb.amazonaws.com https://d1234.cloudfront.net"
  exit 1
fi

API_BASE_URL="$1"
FRONTEND_URL="$2"
MAX_POLLS="${MAX_POLLS:-18}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"

pass_count=0
fail_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf '[FAIL] %s\n' "$1"
}

assert_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '[FAIL] Required command not found: %s\n' "$1"
    exit 1
  fi
}

assert_command curl
assert_command jq

printf 'Running AWS hosted smoke test\n'
printf 'API: %s\n' "${API_BASE_URL}"
printf 'UI : %s\n' "${FRONTEND_URL}"

if mode_payload="$(curl -fsS "${API_BASE_URL}/jobs/mode" 2>/dev/null)"; then
  mode_value="$(printf '%s' "${mode_payload}" | jq -r '.mode // empty')"
  if [[ "${mode_value}" == "AWS_DYNAMODB_SQS" ]]; then
    pass "API mode is AWS_DYNAMODB_SQS"
  else
    fail "API mode expected AWS_DYNAMODB_SQS but got '${mode_value}'"
  fi
else
  fail "Cannot reach API mode endpoint"
  printf 'Summary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
  exit 1
fi

if html="$(curl -fsS "${FRONTEND_URL}" 2>/dev/null)"; then
  if printf '%s' "${html}" | grep -q '<div id="root"></div>'; then
    pass "Frontend URL returned HTML shell"
  else
    fail "Frontend URL responded but root mount element was not found"
  fi
else
  fail "Cannot reach frontend URL"
fi

create_payload='{"message":"smoke-test-aws-hosted"}'
if create_response="$(curl -fsS -X POST "${API_BASE_URL}/jobs" -H 'Content-Type: application/json' -d "${create_payload}")"; then
  job_id="$(printf '%s' "${create_response}" | jq -r '.jobId // empty')"
  if [[ -n "${job_id}" ]]; then
    pass "Created AWS job: ${job_id}"
  else
    fail "Create job succeeded but jobId was missing"
    printf 'Summary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
    exit 1
  fi
else
  fail "Create job request failed"
  printf 'Summary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
  exit 1
fi

final_status=""
for ((i = 1; i <= MAX_POLLS; i++)); do
  job_response="$(curl -fsS "${API_BASE_URL}/jobs/${job_id}")"
  status="$(printf '%s' "${job_response}" | jq -r '.status // empty')"

  if [[ -z "${status}" ]]; then
    fail "Job status missing on poll ${i}"
    break
  fi

  printf 'Poll %d/%d -> status=%s\n' "${i}" "${MAX_POLLS}" "${status}"
  final_status="${status}"

  if [[ "${status}" == "COMPLETED" ]]; then
    result_text="$(printf '%s' "${job_response}" | jq -r '.result // empty')"
    if [[ -n "${result_text}" ]]; then
      pass "AWS job reached COMPLETED with a result"
    else
      fail "AWS job reached COMPLETED but result is missing"
    fi
    break
  fi

  sleep "${SLEEP_SECONDS}"
done

if [[ "${final_status}" != "COMPLETED" ]]; then
  fail "AWS job did not reach COMPLETED within ${MAX_POLLS} polls"
fi

printf 'Summary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
