#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016  # *_OUT/*_RC vars and the single-quoted condition
# strings are consumed inside assert_true's eval, which shellcheck cannot follow
set -e

# Test script for the Terraform provider mirror shared helper.
# Exercises validate/run.sh with the helper active and asserts:
#   * a populated mirror serves providers with the network unreachable
#   * the tier's own TF_PLUGIN_CACHE_DIR is itself a mirror source, which is what
#     makes a cold run converge after the first directory pays for a provider
#   * a caller that already set a Terraform CLI config file is never overridden
#   * TF_PROVIDER_MIRROR=off restores the pure-registry behaviour
#   * an existing complete lock file keeps its `zh:` hashes
#
# Uses only the `null` provider so the tests need one small download rather
# than a cloud provider, and no credentials of any kind.
#
# The offline assertions block the network by pointing the proxy variables at a
# closed port. That is the only way to make them falsifiable: asserting that a
# mirrored `init` merely SUCCEEDS proves nothing, because it would also succeed
# by going to the registry. With the proxy set, success is only possible if no
# request was attempted at all.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/terraform/validate/run.sh"
LIB_SH="$SCRIPTS_DIR/global/scripts/shared/terraform-provider-mirror.sh"
TEST_DIR="$(mktemp -d)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

if ! command -v terraform > /dev/null 2>&1; then
  echo -e "${YELLOW}SKIP: terraform not on PATH; the provider mirror cannot be exercised.${NC}"
  exit 0
fi

make_valid_root() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/main.tf" << 'EOF'
terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

resource "null_resource" "example" {}
EOF
}

run_validate() {
  local repo="$1"
  shift
  (cd "$repo" && REPORT_PATH="build/reports" "$@" "$RUN_SH")
}

# Point the proxy variables at a closed port so any outbound HTTP(S) attempt
# fails immediately instead of hanging. `NO_PROXY` is cleared so nothing can slip
# past the block.
OFFLINE_ENV=(env HTTPS_PROXY=http://127.0.0.1:1 HTTP_PROXY=http://127.0.0.1:1 NO_PROXY= no_proxy=)

echo "== the helper declines cleanly when there is nothing to mirror =="
# Sourcing the library and calling it with every candidate unset must report a
# miss and return non-zero, never leave a half-written config behind.
NOMIRROR_OUT="$(env -i PATH="$PATH" HOME="$TEST_DIR/no-home" sh -c \
  ". '$LIB_SH'; provider_mirror_configure; echo \"rc=\$?\"; echo \"config=[\${TF_PROVIDER_MIRROR_CONFIG:-}]\"" 2>&1)"
assert_true "returns non-zero" '[[ "$NOMIRROR_OUT" == *"rc=1"* ]]'
assert_true "publishes no config path" '[[ "$NOMIRROR_OUT" == *"config=[]"* ]]'
assert_true "says why" '[[ "$NOMIRROR_OUT" == *"no local provider store"* ]]'

echo "== TF_PROVIDER_MIRROR=off disables it =="
OFF_OUT="$(env -i PATH="$PATH" HOME="$TEST_DIR" TF_PROVIDER_MIRROR=off sh -c \
  ". '$LIB_SH'; provider_mirror_configure; echo \"rc=\$?\"" 2>&1)"
assert_true "returns non-zero" '[[ "$OFF_OUT" == *"rc=1"* ]]'
assert_true "names the knob" '[[ "$OFF_OUT" == *"disabled via TF_PROVIDER_MIRROR"* ]]'

echo "== a caller's own CLI config file is never overridden =="
EXISTING_TFRC="$TEST_DIR/caller.tfrc"
echo '# the caller owns this' > "$EXISTING_TFRC"
EXISTING_OUT="$(env -i PATH="$PATH" HOME="$TEST_DIR" TF_CLI_CONFIG_FILE="$EXISTING_TFRC" sh -c \
  ". '$LIB_SH'; provider_mirror_configure; echo \"rc=\$?\"" 2>&1)"
assert_true "returns non-zero" '[[ "$EXISTING_OUT" == *"rc=1"* ]]'
assert_true "says it stood down" '[[ "$EXISTING_OUT" == *"already set a Terraform CLI config"* ]]'
assert_true "leaves the caller's file untouched" \
  "grep -q 'the caller owns this' '$EXISTING_TFRC'"

# ---------------------------------------------------------------------------
# Everything below needs a populated provider store. Build one with a single
# real `terraform init`; if that cannot reach the registry the machine is
# offline, and the remaining assertions are skipped rather than failed.
# ---------------------------------------------------------------------------
MIRROR_DIR="$TEST_DIR/mirror"
SEED_REPO="$TEST_DIR/seed"
mkdir -p "$MIRROR_DIR"
make_valid_root "$SEED_REPO"
(cd "$SEED_REPO" && TF_PLUGIN_CACHE_DIR="$MIRROR_DIR" terraform init -backend=false -input=false -no-color) \
  > /dev/null 2>&1 || true

if [ ! -d "$MIRROR_DIR/registry.terraform.io/hashicorp/null" ]; then
  echo -e "${YELLOW}SKIP: could not populate a provider store (no registry access); skipping the offline assertions.${NC}"
  echo ""
  echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
  exit $?
fi

echo "== a populated mirror serves providers with the network unreachable =="
MIRROR_REPO="$TEST_DIR/mirrored"
make_valid_root "$MIRROR_REPO/stacks/app"
MIRROR_RC=0
MIRROR_OUT="$(run_validate "$MIRROR_REPO" "${OFFLINE_ENV[@]}" TF_PROVIDER_MIRROR_DIR="$MIRROR_DIR" 2>&1)" || MIRROR_RC=$?
assert_true "exits 0 with no network" "[ $MIRROR_RC -eq 0 ]"
assert_true "validates the root module" '[[ "$MIRROR_OUT" == *"1 passed, 0 failed"* ]]'
assert_true "announces the mirror" '[[ "$MIRROR_OUT" == *"provider mirror: serving"* ]]'
assert_true "names the store it used" '[[ "$MIRROR_OUT" == *"$MIRROR_DIR"* ]]'

echo "== negative control: the same run without the mirror cannot pass =="
# Without this, the assertion above would hold even if the helper did nothing and
# the machine simply had a warm cache somewhere. `TF_PROVIDER_MIRROR=off` with a
# workspace-local plugin cache leaves the registry as the only source, and the
# registry is unreachable.
CONTROL_REPO="$TEST_DIR/control"
make_valid_root "$CONTROL_REPO/stacks/app"
CONTROL_RC=0
CONTROL_OUT="$(run_validate "$CONTROL_REPO" "${OFFLINE_ENV[@]}" \
  TF_PROVIDER_MIRROR=off TF_INIT_MAX_ATTEMPTS=1 2>&1)" || CONTROL_RC=$?
assert_true "exits non-zero" "[ $CONTROL_RC -ne 0 ]"
assert_true "fails on the unreachable registry" '[[ "$CONTROL_OUT" == *"0 passed, 1 failed"* ]]'

echo "== the tier's own plugin cache is itself a mirror source =="
# This is the within-run convergence path: the online fallback writes into
# TF_PLUGIN_CACHE_DIR, so the NEXT root module needing that provider is served
# locally. Pre-seeding that same variable proves the helper searches it, without
# needing two sequential roots and a half-open network.
CONVERGE_REPO="$TEST_DIR/converge"
make_valid_root "$CONVERGE_REPO/stacks/one"
make_valid_root "$CONVERGE_REPO/stacks/two"
CONVERGE_RC=0
CONVERGE_OUT="$(run_validate "$CONVERGE_REPO" "${OFFLINE_ENV[@]}" TF_PLUGIN_CACHE_DIR="$MIRROR_DIR" 2>&1)" || CONVERGE_RC=$?
assert_true "exits 0 with no network" "[ $CONVERGE_RC -eq 0 ]"
assert_true "validates both root modules" '[[ "$CONVERGE_OUT" == *"2 passed, 0 failed"* ]]'

echo "== an existing complete lock file keeps its zh: hashes =="
# An unpacked mirror can only compute `h1:` hashes. Without `-lockfile=readonly`
# an offline init that had to write an entry would strip the `zh:` hashes and
# leave a lock file valid on this platform only.
#
# The seed init deliberately uses its own EMPTY cache directory. Installing from
# a warm plugin cache is itself a path that can only record `h1:`, so seeding
# through `$MIRROR_DIR` would produce a lock file with no `zh:` hashes at all and
# the preservation assertion below would pass vacuously.
LOCK_REPO="$TEST_DIR/lock"
LOCK_SEED_CACHE="$TEST_DIR/lock-seed-cache"
mkdir -p "$LOCK_SEED_CACHE"
make_valid_root "$LOCK_REPO/stacks/app"
(cd "$LOCK_REPO/stacks/app" && TF_PLUGIN_CACHE_DIR="$LOCK_SEED_CACHE" terraform init -backend=false -input=false -no-color) \
  > /dev/null 2>&1 || true
LOCK_FILE="$LOCK_REPO/stacks/app/.terraform.lock.hcl"
ZH_BEFORE=0
[ -f "$LOCK_FILE" ] && ZH_BEFORE="$(grep -c '"zh:' "$LOCK_FILE" || true)"
rm -rf "$LOCK_REPO/stacks/app/.terraform"
run_validate "$LOCK_REPO" "${OFFLINE_ENV[@]}" TF_PROVIDER_MIRROR_DIR="$MIRROR_DIR" > /dev/null 2>&1 || true
ZH_AFTER=0
[ -f "$LOCK_FILE" ] && ZH_AFTER="$(grep -c '"zh:' "$LOCK_FILE" || true)"

assert_true "the seed run produced zh: hashes to protect" "[ '$ZH_BEFORE' -gt 0 ]"
assert_true "the mirrored run preserved every one of them" "[ '$ZH_BEFORE' -eq '$ZH_AFTER' ]"

echo "== the generated CLI config is cleaned up =="
assert_true "no stray tfrc is left in the workspace" \
  "! find '$MIRROR_REPO' -name '*.tfrc' | grep -q ."

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
