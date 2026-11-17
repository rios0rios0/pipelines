#!/usr/bin/env bash
set -e

# Hold the retry contract of `terraform_init_cached`
# (`global/scripts/shared/terraform-provider-mirror.sh`): a failed online `init`
# is retried after a growing wait, and every wait of a run draws on ONE budget.
#
# Why a dedicated regression test exists:
#
# Each attempt of an `init` whose module sources cannot be resolved can spend a
# minute in resolver timeouts, and a resolver outage on a CI machine outlasted
# the four attempts and 30 s of waiting the loop used to have, failing a test
# job whose every test then passed on a retry of the job. Waiting longer for
# EVERY directory is not the answer: a failure the whole tree shares (a missing
# credential, a deleted ref) would then stretch a run past its time limit. So
# the patience is spent once -- the first directories to fail get it, and once
# the budget is gone the rest fail after one attempt. The runners call the
# helper in subshells, so the budget must survive them.
#
# `terraform` and `sleep` are stubs on PATH: the stub fails as many times as the
# directory's `.fails` file says, and `sleep` records the wait instead of
# sleeping it.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$SCRIPTS_DIR/global/scripts/shared/terraform-provider-mirror.sh"
TEST_DIR="$(mktemp -d)" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_equal() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (expected [$expected], got [$actual])${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/terraform" << 'EOF'
#!/usr/bin/env sh
# terraform -chdir=<dir> init ...: fail while <dir>/.fails is above zero.
dir="${1#-chdir=}"
echo x >> "$dir/.calls"
n="$(cat "$dir/.fails" 2> /dev/null || echo 0)"
if [ "$n" -gt 0 ]; then
  echo "$((n - 1))" > "$dir/.fails"
  echo "Error: Failed to download module (stub)" >&2
  exit 1
fi
exit 0
EOF
cat > "$TEST_DIR/bin/sleep" << EOF
#!/usr/bin/env sh
echo "\$1" >> "$TEST_DIR/sleeps"
EOF
chmod +x "$TEST_DIR/bin/terraform" "$TEST_DIR/bin/sleep"

# new_dir <name> <failures before success>
new_dir() {
  mkdir -p "$TEST_DIR/$1"
  echo "$2" > "$TEST_DIR/$1/.fails"
  : > "$TEST_DIR/$1/.calls"
}
calls() { wc -l < "$TEST_DIR/$1/.calls" | tr -d ' '; }
sleeps() { if [ -f "$TEST_DIR/sleeps" ]; then paste -sd' ' "$TEST_DIR/sleeps"; else echo ''; fi; }
total_sleep() { if [ -f "$TEST_DIR/sleeps" ]; then awk '{ s += $1 } END { print s + 0 }' "$TEST_DIR/sleeps"; else echo 0; fi; }

# run_dirs [VAR=value...] -- <dir>...: one fresh shell that sets the defaults
# once and inits each directory in a subshell, as the runners do. Prints one
# `<dir> <rc>` line per directory.
run_dirs() {
  local -a vars=()
  while [ "$1" != '--' ]; do
    vars+=("$1")
    shift
  done
  shift
  rm -f "$TEST_DIR/sleeps"
  # shellcheck disable=SC2016 # the script expands in the child shell
  env -u TF_PROVIDER_MIRROR_CONFIG -u TF_PROVIDER_MIRROR_FALLBACK_CONFIG "${vars[@]}" \
    PATH="$TEST_DIR/bin:$PATH" TEST_DIR="$TEST_DIR" sh -c '
      . "$0"
      terraform_init_retry_defaults
      for d in "$@"; do
        if (terraform_init_cached "$TEST_DIR/$d" -backend=false > /dev/null 2>&1); then
          echo "$d 0"
        else
          echo "$d 1"
        fi
      done
      echo "budget-file-left ${TF_INIT_RETRY_SPENT_FILE:+yes}"
      provider_mirror_cleanup
      [ -z "${TF_INIT_RETRY_SPENT_FILE:-}" ] && echo "budget-file-cleaned yes"
    ' "$HELPER" "$@"
}

echo "== a passing blip clears on a retry, after a growing wait =="
new_dir blip 2
out="$(run_dirs -- blip)"
assert_equal "the init succeeds" "blip 0" "$(grep '^blip ' <<< "$out")"
assert_equal "on the third attempt" 3 "$(calls blip)"
assert_equal "waiting 15 s, then 30 s" "15 30" "$(sleeps)"

echo "== the waits of a whole run share one budget =="
new_dir first 99
new_dir second 99
new_dir third 99
out="$(run_dirs -- first second third)"
assert_equal "the first directory fails" "first 1" "$(grep '^first ' <<< "$out")"
assert_equal "after all six attempts" 6 "$(calls first)"
assert_equal "the second directory gets what is left, then stops" 4 "$(calls second)"
assert_equal "the third fails after one attempt" 1 "$(calls third)"
assert_equal "the waits are 15 30 45 60 75, then 15 30 30" "15 30 45 60 75 15 30 30" "$(sleeps)"
assert_equal "and add up to the 300 s budget" 300 "$(total_sleep)"
assert_equal "the budget file is cleaned up" "budget-file-cleaned yes" "$(grep '^budget-file-cleaned' <<< "$out")"

echo "== a zero budget turns the retries off =="
new_dir zero 1
out="$(run_dirs TF_INIT_RETRY_BUDGET=0 -- zero)"
assert_equal "the init fails" "zero 1" "$(grep '^zero ' <<< "$out")"
assert_equal "after one attempt" 1 "$(calls zero)"
assert_equal "without waiting" "" "$(sleeps)"

echo "== a caller that never set the defaults keeps its per-directory waits =="
new_dir legacy 2
rm -f "$TEST_DIR/sleeps"
rc=0
# shellcheck disable=SC2016 # the script expands in the child shell
env -u TF_PROVIDER_MIRROR_CONFIG -u TF_PROVIDER_MIRROR_FALLBACK_CONFIG -u TF_INIT_RETRY_SPENT_FILE \
  PATH="$TEST_DIR/bin:$PATH" TF_INIT_MAX_ATTEMPTS=3 TF_INIT_RETRY_DELAY=1 \
  sh -c '. "$0"; terraform_init_cached "$1" -backend=false > /dev/null 2>&1' "$HELPER" "$TEST_DIR/legacy" || rc=$?
assert_equal "the init succeeds" 0 "$rc"
assert_equal "on the third attempt" 3 "$(calls legacy)"
assert_equal "waiting 1 s, then 2 s" "1 2" "$(sleeps)"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
