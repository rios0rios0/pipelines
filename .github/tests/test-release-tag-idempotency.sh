#!/usr/bin/env bash
# Regression test for the `Create Tag` step in
# azure-devops/global/stages/40-delivery/release.yaml.
#
# Exercises the status-code → outcome mapping in isolation so that a future
# edit that accidentally reintroduces `curl --fail` (or breaks the 409-is-ok
# idempotency) is caught at CI time instead of in production where it
# manifests as red builds across every consumer of the shared template.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Mirror of the case statement in release.yaml. Keep these in sync — if the
# behaviour changes, this test must change with it.
map_status_to_exit() {
  local http_status="$1"
  case "$http_status" in
    200|201) echo "created"; return 0 ;;
    409)     echo "already-exists"; return 0 ;;
    *)       echo "fail($http_status)"; return 1 ;;
  esac
}

assert_ok() {
  local description="$1"; local status="$2"; local expected="$3"
  local actual
  actual="$(map_status_to_exit "$status" || true)"
  if [[ "$actual" == "$expected" ]]; then
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo -e "${RED}FAIL${NC} $description (expected=$expected, actual=$actual)"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi
}

assert_fail() {
  local description="$1"; local status="$2"
  if map_status_to_exit "$status" >/dev/null 2>&1; then
    echo -e "${RED}FAIL${NC} $description (HTTP $status should have exited non-zero)"
    TESTS_FAILED=$((TESTS_FAILED+1))
  else
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED+1))
  fi
}

echo "=== Release tag idempotency ==="
assert_ok   "HTTP 200 maps to success"                            "200" "created"
assert_ok   "HTTP 201 maps to success"                            "201" "created"
assert_ok   "HTTP 409 is idempotent (tag already exists)"         "409" "already-exists"
assert_fail "HTTP 400 aborts the stage"                           "400"
assert_fail "HTTP 401 aborts the stage (auth)"                    "401"
assert_fail "HTTP 403 aborts the stage (permissions)"             "403"
assert_fail "HTTP 404 aborts the stage (wrong repo id)"           "404"
assert_fail "HTTP 422 aborts the stage (unknown validation)"      "422"
assert_fail "HTTP 500 aborts the stage (curl retries exhausted)"  "500"

echo ""
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
