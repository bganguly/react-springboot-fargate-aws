#!/usr/bin/env bash
set -euo pipefail

UI_BASE_URL="${UI_BASE_URL:-http://localhost:5173}"
ALT_UI_BASE_URL="${ALT_UI_BASE_URL:-http://localhost:5174}"

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

check_ui_url() {
  local target_url="$1"
  local html

  if ! html="$(curl -fsS "${target_url}" 2>/dev/null)"; then
    return 1
  fi

  if printf '%s' "${html}" | grep -q '<div id="root"></div>'; then
    printf '%s\n' "${target_url}"
    return 0
  fi

  return 1
}

printf 'Running local UI smoke test\n'

if detected_url="$(check_ui_url "${UI_BASE_URL}")"; then
  pass "UI responded at ${detected_url}"
elif detected_url="$(check_ui_url "${ALT_UI_BASE_URL}")"; then
  pass "UI responded at fallback ${detected_url}"
else
  fail "UI not reachable at ${UI_BASE_URL} or ${ALT_UI_BASE_URL}. Start frontend first (npm run dev)."
fi

printf 'Summary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
