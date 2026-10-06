#!/usr/bin/env bash
set -e

# Test script for the scanner markers `golangci-lint/run.sh --fix` must leave in place.
#
# nolintlint fixes an unused `//nolint` directive by deleting the whole comment it sits in, and a
# test fixture often shares that comment with another scanner's allow marker:
#
#   fixture := "..." //nolint:gosec //gitleaks:allow
#
# gosec never runs on `_test.go` (the shared config excludes it there), so the directive is always
# "unused", and `make lint` -- which runs with `--fix` -- deleted the gitleaks marker without
# reporting anything. The next Gitleaks scan then failed on the fixture. The shared config now
# leaves nolintlint's finding alone on a line that carries such a marker; this suite runs the real
# script with `--fix` and checks both halves: the marked lines keep their comment, and an ordinary
# unused directive is still removed, so the exclusion cannot quietly widen into "never fix".

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh"
TEST_DIR="$(mktemp -d)" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1"
  local condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

MODULE="$TEST_DIR/module"
mkdir -p "$MODULE"
cat > "$MODULE/go.mod" <<'EOF'
module example.com/markers

go 1.27
EOF
cat > "$MODULE/markers.go" <<'EOF'
// Package markers holds nothing; its test carries the fixtures.
package markers
EOF
cat > "$MODULE/markers_test.go" <<'EOF'
package markers_test

import "testing"

func TestFixtures(t *testing.T) {
	t.Parallel()

	gitleaksFixture := "fixture-token-placeholder" //nolint:gosec //gitleaks:allow
	semgrepFixture := "fixture-other-placeholder" //nolint:gosec // nosemgrep: fixture-rule
	plainFixture := "fixture-plain-placeholder" //nolint:gosec // nothing else shares this comment
	if gitleaksFixture == "" || semgrepFixture == "" || plainFixture == "" {
		t.Fail()
	}
}
EOF

FIXTURE="$MODULE/markers_test.go"

echo ""
echo "Test 1: run.sh --fix keeps the comments that carry a scanner marker"
STATUS=0
(cd "$MODULE" && "$RUN_SH" --fix) > "$TEST_DIR/lint.log" 2>&1 || STATUS=$?
[ "$STATUS" -eq 0 ] || cat "$TEST_DIR/lint.log"
assert_true "the lint run succeeds" "[ $STATUS -eq 0 ]"
# gofmt aligns the trailing comments of adjacent lines, so the gap before `//nolint` may grow.
assert_true "the gitleaks marker survives the fix" \
  "grep -Eq 'gitleaksFixture := \"fixture-token-placeholder\" +//nolint:gosec //gitleaks:allow\$' '$FIXTURE'"
assert_true "the nosemgrep marker survives the fix" \
  "grep -Eq 'semgrepFixture := \"fixture-other-placeholder\" +//nolint:gosec // nosemgrep: fixture-rule\$' '$FIXTURE'"

echo ""
echo "Test 2: run.sh --fix still removes an unused directive that carries no marker"
assert_true "the plain unused directive is removed" \
  "grep -Eq 'plainFixture := \"fixture-plain-placeholder\"\$' '$FIXTURE'"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
