#!/usr/bin/env bash
set -e

# Pin the multi-arch contract on the shared `40-delivery/docker` composite
# action.
#
# Why a dedicated regression test exists:
#
# `code-guru` rolled out to an AKS cluster with `aks-workersarm-*` ARM
# workers and crashlooped with `exec /usr/local/bin/code-guru: exec format
# error` because the published image was a single-arch `linux/amd64`
# manifest. The fix wires `setup-qemu-action` + `setup-buildx-action`
# ahead of `docker/build-push-action` and exposes a `platforms` input that
# defaults to `linux/amd64,linux/arm64`. Each of those four pieces has a
# distinct silent-failure mode if it regresses:
#
#   - missing `setup-buildx-action` → default Docker builder silently
#     ignores `platforms:` and emits a single-arch manifest;
#   - missing `setup-qemu-action` → multi-arch builds that exec foreign-arch
#     binaries inside a `RUN` step (e.g., installer scripts) fail with a
#     misleading `exec format error` on the BUILD side;
#   - `platforms` input dropped or default narrowed to `linux/amd64` →
#     consumers silently regress to single-arch images;
#   - `platforms` not wired through `with:` on the build step → the input
#     is accepted but ignored, producing a silently single-arch manifest.
#
# These assertions catch each one before it ships.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_FILE="$SCRIPTS_DIR/github/global/stages/40-delivery/docker/action.yaml"

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

assert_yq() {
  local description="$1"
  local expression="$2"
  local expected="$3"
  local actual
  actual=$(yq "$expression" "$ACTION_FILE")
  if [ "$actual" = "$expected" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (got: '$actual', expected: '$expected')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# given: the shared docker delivery action exists at the canonical path
echo "=== Multi-arch contract on $ACTION_FILE ==="
assert_true \
  "the action file must exist (path is canonical and consumed by every *-docker.yaml workflow)" \
  "[ -f '$ACTION_FILE' ]"

# when: the file is parsed as YAML
# then: every piece of the multi-arch contract must be present
assert_yq \
  "the 'platforms' input must be declared so consumers can override at the call-site" \
  '.inputs.platforms.type' \
  'string'

assert_yq \
  "the 'platforms' default must publish a multi-arch manifest list (amd64 AND arm64), not a single-arch image" \
  '.inputs.platforms.default' \
  'linux/amd64,linux/arm64'

assert_yq \
  "'platforms' must be optional (consumers do not have to specify it for the multi-arch default to apply)" \
  '.inputs.platforms.required' \
  'false'

assert_true \
  "'docker/setup-qemu-action' step must be present so RUN steps in arm64 builds can exec foreign-arch binaries via binfmt" \
  "yq -e '.runs.steps[] | select(.uses == \"docker/setup-qemu-action@v3\")' '$ACTION_FILE' >/dev/null"

assert_true \
  "'docker/setup-buildx-action' step must be present — the default Docker builder silently ignores 'platforms:' and emits a single-arch manifest" \
  "yq -e '.runs.steps[] | select(.uses == \"docker/setup-buildx-action@v3\")' '$ACTION_FILE' >/dev/null"

assert_yq \
  "'platforms' must be wired into the 'docker/build-push-action' step's 'with:' so the input actually reaches the build" \
  '(.runs.steps[] | select(.uses | test("^docker/build-push-action"))).with.platforms' \
  '${{ inputs.platforms }}'

# Given the dependency on the build-push-action, also pin the action major
# so a future bump that drops multi-arch support has to surface here.
assert_true \
  "'docker/build-push-action' must be at least v6 (multi-arch via buildx is stable from v6 onwards)" \
  "yq -e '.runs.steps[] | select(.uses | test(\"^docker/build-push-action@v([6-9]|[1-9][0-9]+)$\"))' '$ACTION_FILE' >/dev/null"

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
