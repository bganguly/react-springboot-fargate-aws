#!/usr/bin/env bash
set -euo pipefail

API_BASE_URL="${API_BASE_URL:-http://localhost:8080}"
MAX_POLLS="${MAX_POLLS:-12}"
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"

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

printf 'Running local backend smoke test against %s\n' "${API_BASE_URL}"

if mode_payload="$(curl -fsS "${API_BASE_URL}/jobs/mode" 2>/dev/null)"; then
  mode_value="$(printf '%s' "${mode_payload}" | jq -r '.mode // empty')"
  if [[ -n "${mode_value}" ]]; then
    pass "Mode endpoint responded with mode=${mode_value}"
  else
    fail "Mode endpoint responded without a mode field"
  fi
else
  fail "Cannot reach backend at ${API_BASE_URL}. Start backend first (npm run dev:backend)."
  printf 'Summary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
  exit 1
fi

create_payload='{"message":"smoke-test-local-backend"}'
if create_response="$(curl -fsS -X POST "${API_BASE_URL}/jobs" -H 'Content-Type: application/json' -d "${create_payload}")"; then
  job_id="$(printf '%s' "${create_response}" | jq -r '.jobId // empty')"
  if [[ -n "${job_id}" ]]; then
    pass "Created job: ${job_id}"
  else
    fail "Create job succeeded but jobId was missing"
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
      pass "Job reached COMPLETED with a result"
    else
      fail "Job reached COMPLETED but result is missing"
    fi
    break
  fi

  sleep "${SLEEP_SECONDS}"
done

if [[ "${final_status}" != "COMPLETED" ]]; then
  fail "Job did not reach COMPLETED within ${MAX_POLLS} polls"
fi

printf 'Summary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
