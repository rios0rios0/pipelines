#!/usr/bin/env bash
set -e

# Hold the contract that a source-built Go tool is rebuilt when it goes stale.
#
# Why this regression test exists:
#
# `go install` compiles the tool from source, so the resulting binary carries
# the Go toolchain that built it. A cache check written as "install only when
# the file is absent" therefore reuses a binary forever -- across Go upgrades
# and across pin changes alike. Both failure modes have already happened:
#
#   - after the pinned Go moved from 1.26 to 1.27, every consumer's
#     `sca:govulncheck` job failed with "Loading packages failed, possibly due
#     to a mismatch between the Go version used to build govulncheck and the Go
#     version on PATH". The scan reported ZERO findings, so the job looked like
#     a security failure while actually never having analysed anything;
#   - a leftover binary of a different version satisfied the existence check, so
#     a version bump in `pinned-versions.sh` silently did not apply.
#
# Neither is visible in a diff, and neither reproduces on a fresh runner, which
# is exactly why they are asserted here against the FILE rather than against a
# resolved pipeline.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAILURES=0

assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  ✓ $description"
  else
    echo "  ✗ $description"
    echo "      expected to find: $needle"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_contains() {
  local description="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  ✗ $description"
    echo "      expected NOT to find: $needle"
    FAILURES=$((FAILURES + 1))
  else
    echo "  ✓ $description"
  fi
}

echo "1. govulncheck is reinstalled when the cached binary is stale"

GOVULNCHECK_SCRIPT="$REPO_ROOT/global/scripts/languages/golang/govulncheck/run.sh"
[[ -f "$GOVULNCHECK_SCRIPT" ]] || { echo "  ✗ $GOVULNCHECK_SCRIPT is missing"; exit 1; }
GOVULNCHECK_CONTENT="$(cat "$GOVULNCHECK_SCRIPT")"

assert_not_contains \
  "the install is not gated on the binary merely existing" \
  "$GOVULNCHECK_CONTENT" \
  'if [ ! -f "$GOVULNCHECK_BIN" ]; then'

assert_contains \
  "the cached binary's build info is read" \
  "$GOVULNCHECK_CONTENT" \
  'go version -m "$GOVULNCHECK_BIN"'

# Asserted as the whole comparison, not just the operands: a substring like
# `$GOVULNCHECK_VERSION` also appears in the install line, so matching it alone
# would keep passing if a refactor dropped the comparison but kept the install.
assert_contains \
  "the Go that built it is compared against the Go on PATH" \
  "$GOVULNCHECK_CONTENT" \
  '[ "$govulncheckBuiltWith" = "$(go env GOVERSION)" ]'

assert_contains \
  "the cached binary's module version is compared against the pin" \
  "$GOVULNCHECK_CONTENT" \
  '[ "$govulncheckBuiltVersion" = "$GOVULNCHECK_VERSION" ]'

echo ""
echo "2. a failed scan explains itself in the log"

# The scan writes to the report file, so without this the log carries only the
# shell's exit code -- and "found vulnerabilities" and "could not scan" look
# identical to whoever is reading the build.
assert_contains \
  "the report's head is echoed when the scan exits non-zero" \
  "$GOVULNCHECK_CONTENT" \
  'head -n 40 "$fileName"'

echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES assertion(s)"
  exit 1
fi
echo "PASSED"
