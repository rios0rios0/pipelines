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

echo "== the terra store is derived from XDG_CACHE_HOME, then HOME, then not at all =="
# Each arm is asserted against a store that only that arm can find, so getting the
# branching wrong fails the suite instead of silently falling through to another
# candidate. The both-unset arm is the one that matters: spelling this
# `${XDG_CACHE_HOME:-${HOME:-}/.cache}` yields `/.cache/terra/providers`, which is
# ABSOLUTE and therefore slips past the relative-path guard.
#
# These probe the derived path itself rather than the finished config, and that
# is deliberate. The both-unset case is only reachable through the derivation:
# the finished config filters every candidate through `[ -d ... ]`, and
# `/.cache/terra/providers` does not exist on a normal machine and cannot be
# created without root — so a config-level assertion would pass just as happily
# against the broken expansion. POSIX `sh` has no `local`, so the derivation
# variable survives the call and can be read directly.
XDG_STORE="$TEST_DIR/xdg-home/terra/providers"
HOME_STORE="$TEST_DIR/real-home/.cache/terra/providers"
mkdir -p "$XDG_STORE" "$HOME_STORE"
derive_terra_dir() {
  env -i PATH="$PATH" "$@" sh -c \
    ". '$LIB_SH'; provider_mirror_configure > /dev/null 2>&1; printf '%s' \"\${provider_mirror_terra_dir}\""
}
XDG_DERIVED="$(derive_terra_dir XDG_CACHE_HOME="$TEST_DIR/xdg-home" HOME="$TEST_DIR/real-home")"
HOME_DERIVED="$(derive_terra_dir HOME="$TEST_DIR/real-home")"
NONE_DERIVED="$(derive_terra_dir TF_PROVIDER_MIRROR_DIR="$XDG_STORE")"
XDG_CONF="$(env -i PATH="$PATH" XDG_CACHE_HOME="$TEST_DIR/xdg-home" HOME="$TEST_DIR/real-home" sh -c \
  ". '$LIB_SH'; provider_mirror_configure > /dev/null 2>&1; cat \"\${TF_PROVIDER_MIRROR_CONFIG:-/dev/null}\"")"

assert_true "XDG_CACHE_HOME wins when set" "[ '$XDG_DERIVED' = '$XDG_STORE' ]"
assert_true "and HOME's store is not also picked up" '[[ "$XDG_CONF" != *"$HOME_STORE"* ]]'
assert_true "the resolved store reaches the generated config" '[[ "$XDG_CONF" == *"$XDG_STORE"* ]]'
assert_true "HOME is used when XDG_CACHE_HOME is unset" "[ '$HOME_DERIVED' = '$HOME_STORE' ]"
assert_true "nothing is guessed when both are unset" "[ -z '$NONE_DERIVED' ]"

echo "== a declining call clears BOTH config paths =="
# Every decline has to leave `terraform_init_cached` with nothing to reach for.
# Seed both variables with paths that no longer exist, the way a second call in
# the same shell would see them, and require the decline to clear them — a stale
# fallback path would otherwise be handed to Terraform as a config file that
# `provider_mirror_cleanup` has already deleted.
for decline in "TF_PROVIDER_MIRROR=off" "TF_CLI_CONFIG_FILE=$TEST_DIR/caller.tfrc"; do
  DECLINE_OUT="$(env -i PATH="$PATH" HOME="$TEST_DIR/no-home" "$decline" sh -c \
    ". '$LIB_SH'
     TF_PROVIDER_MIRROR_CONFIG=/nonexistent/stale-primary
     TF_PROVIDER_MIRROR_FALLBACK_CONFIG=/nonexistent/stale-fallback
     provider_mirror_configure > /dev/null 2>&1
     printf 'primary=[%s] fallback=[%s]' \"\${TF_PROVIDER_MIRROR_CONFIG:-}\" \"\${TF_PROVIDER_MIRROR_FALLBACK_CONFIG:-}\"")"
  assert_true "declining via ${decline%%=*} clears both paths" \
    '[[ "$DECLINE_OUT" == "primary=[] fallback=[]" ]]'
done

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

echo "== a mirror hit leaves the plugin cache free of symlinks =="
# The regression this pins: running the mirror attempt with TF_PLUGIN_CACHE_DIR
# still set makes Terraform populate the cache with a SYMLINK into the mirror.
# Nothing fails at that moment — the damage lands on the next online install,
# which cannot write a real package over a symlink and fails deterministically
# with "cannot install package into target directory ... because it is a symlink".
#
# The run's exit status is asserted BEFORE the symlink check, and that ordering is
# the point. An `init` that failed outright writes no symlink either, so checking
# only for symlinks would pass for the wrong reason — the same vacuous shape as
# asserting on a path the test never creates.
SYMLINK_REPO="$TEST_DIR/symlink"
SYMLINK_CACHE="$TEST_DIR/symlink-cache"
mkdir -p "$SYMLINK_CACHE"
make_valid_root "$SYMLINK_REPO/stacks/app"
SYMLINK_RC=0
SYMLINK_OUT="$(run_validate "$SYMLINK_REPO" "${OFFLINE_ENV[@]}" \
  TF_PROVIDER_MIRROR_DIR="$MIRROR_DIR" TF_PLUGIN_CACHE_DIR="$SYMLINK_CACHE" 2>&1)" || SYMLINK_RC=$?

assert_true "the mirrored init actually succeeded" "[ $SYMLINK_RC -eq 0 ]"
assert_true "and the mirror is what served it, with the network unreachable" \
  '[[ "$SYMLINK_OUT" == *"1 passed, 0 failed"* ]]'
assert_true "the mirrored init wrote no symlink into the plugin cache" \
  "[ -z \"\$(find '$SYMLINK_CACHE' -type l 2>/dev/null)\" ]"

echo "== a fallback still works against a cache a mirror hit already touched =="
# End-to-end version of the same regression: mirror-serve one root, then force a
# root the mirror cannot satisfy through the online fallback using that very
# cache. This is the exact sequence that failed in CI.
FALLBACK_REPO="$TEST_DIR/fallback"
FALLBACK_CACHE="$TEST_DIR/fallback-cache"
mkdir -p "$FALLBACK_CACHE"
make_valid_root "$FALLBACK_REPO/stacks/one"
make_valid_root "$FALLBACK_REPO/stacks/two"
FALLBACK_RC=0
FALLBACK_OUT="$(run_validate "$FALLBACK_REPO" env \
  TF_PROVIDER_MIRROR_DIR="$MIRROR_DIR" TF_PLUGIN_CACHE_DIR="$FALLBACK_CACHE" TF_INIT_MAX_ATTEMPTS=1 2>&1)" || FALLBACK_RC=$?
assert_true "both roots initialise" "[ $FALLBACK_RC -eq 0 ]"
assert_true "and nothing reports the symlink error" \
  '[[ "$FALLBACK_OUT" != *"because it is a symlink"* ]]'

echo "== a mirror miss still serves the providers the mirror does hold =="
# This is what made two root modules keep failing after the mirror shipped. One
# provider the mirror cannot satisfy sends the whole directory to the fallback,
# and a pure-`direct` fallback then re-resolves EVERY provider from the registry
# -- including the ones sitting in the mirror, whose checksums come from github.
# The fallback keeps the mirror in play, so only the genuine miss goes out.
#
# The mirrored provider is pinned to a version the mirror holds and the missing
# one to a version that exists nowhere locally; with the network blocked, the
# whole init must fail (the miss is unreachable) while the mirrored provider is
# still resolved locally, which the log line proves.
#
# The network is deliberately LEFT UP here, because that is the failing condition
# in production: `registry.terraform.io` is reachable and github is the throttled
# host. It is also the only way to tell the two fallbacks apart — with the
# network blocked, both fail identically on the registry version query, so an
# offline assertion cannot see the difference.
#
# The discriminator is Terraform's own install line. A provider taken from a
# filesystem mirror installs `(unauthenticated)`, because a mirror carries no
# signature; one fetched through `direct` installs `(signed by ...)` after the
# github checksum round trip that is being avoided.
MISS_REPO="$TEST_DIR/miss"
MISS_CACHE="$TEST_DIR/miss-cache"
mkdir -p "$MISS_REPO/stacks/app" "$MISS_CACHE"
cat > "$MISS_REPO/stacks/app/main.tf" << 'EOF'
terraform {
  required_providers {
    null    = { source = "hashicorp/null" }
    missing = { source = "hashicorp/nonexistent-for-tests" }
  }
}
EOF
MISS_OUT="$(run_validate "$MISS_REPO" env \
  TF_PROVIDER_MIRROR_DIR="$MIRROR_DIR" TF_PLUGIN_CACHE_DIR="$MISS_CACHE" TF_INIT_MAX_ATTEMPTS=1 2>&1 || true)"

assert_true "the fallback ran and reported the genuine miss" \
  '[[ "$MISS_OUT" == *"nonexistent-for-tests"* ]]'
assert_true "the mirrored provider was still served by the mirror, not the registry" \
  '[[ "$MISS_OUT" == *"hashicorp/null"*"(unauthenticated)"* ]]'

echo "== a cache poisoned by an earlier revision is repaired =="
# Simulate the artifact the shipped version left behind on persistent agents:
# a leaf symlink pointing into the mirror. It must be removed, because the online
# fallback can never install over it.
POISON_CACHE="$TEST_DIR/poisoned-cache"
POISON_LEAF="$POISON_CACHE/registry.terraform.io/hashicorp/null/9.9.9/linux_amd64"
FOREIGN_LEAF="$POISON_CACHE/registry.terraform.io/hashicorp/other/1.0.0/linux_amd64"
mkdir -p "$(dirname "$POISON_LEAF")" "$(dirname "$FOREIGN_LEAF")" "$TEST_DIR/not-a-mirror"
ln -s "$MIRROR_DIR/registry.terraform.io/hashicorp/null/9.9.9/linux_amd64" "$POISON_LEAF"
ln -s "$TEST_DIR/not-a-mirror" "$FOREIGN_LEAF"
POISON_OUT="$(env -i PATH="$PATH" HOME="$TEST_DIR/real-home" \
  TF_PROVIDER_MIRROR_DIR="$MIRROR_DIR" TF_PLUGIN_CACHE_DIR="$POISON_CACHE" sh -c \
  ". '$LIB_SH'; provider_mirror_configure; provider_mirror_cleanup" 2>&1)"

assert_true "the mirror-pointing symlink is removed" "[ ! -e '$POISON_LEAF' ]"
assert_true "it says so" '[[ "$POISON_OUT" == *"stale symlink"* ]]'
assert_true "a symlink pointing elsewhere is left alone" "[ -L '$FOREIGN_LEAF' ]"

echo "== the generated CLI config is cleaned up =="
assert_true "no stray tfrc is left in the workspace" \
  "! find '$MIRROR_REPO' -name '*.tfrc' | grep -q ."

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
