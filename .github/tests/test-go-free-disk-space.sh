#!/usr/bin/env bash
# The Azure DevOps Go test job's opt-in disk clean-up, `FREE_DISK_SPACE`, and the script it runs,
# global/scripts/languages/golang/free-disk-space/run.sh.
#
# A Microsoft-hosted agent starts with its disk most of the way full of toolchains no Go job uses,
# and a Go test job that compiles a large module twice and pulls several GB of integration-test
# images runs out of the rest. The script removes them, and the template runs it only when the
# consumer asks. Asserts:
#   1. the script removes the Android SDK, the .NET SDKs, GHC, Swift and the tool cache's CodeQL
#      bundles, prunes the Docker images, and logs `df -h` before and after
#   2. it keeps the .NET runtime -- `dotnet`, `host/`, `shared/` -- which the same job's
#      `PublishCodeCoverageResults@2` needs to publish the coverage report
#   3. it removes as root through `sudo -n`, which fails instead of waiting for a password
#   4. a path the image does not carry is skipped, and a removal or prune that fails is reported,
#      and neither fails the job
#   5. `go-docker.yaml` and the tests stage declare `FREE_DISK_SPACE`, a boolean defaulting to
#      `false`, and forward it; the test job runs the script only when it is true, after the Go
#      set-up (the script comes from the scripts checkout) and before `Run Tests`
#
# Every removal runs against a fixture tree (`FREE_DISK_SPACE_ROOT`), with `sudo` and `docker`
# replaced by stubs that record their calls.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/golang/free-disk-space/run.sh"
AZURE="$SCRIPTS_DIR/azure-devops/golang"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (expected '$expected', got '$actual')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_true() {
  local description="$1" condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# The stubs. `sudo` records its arguments and runs the command after `-n`, unless
# FREE_DISK_SPACE_STUB_SUDO_FAILS is set; `docker` records its arguments and exits with
# FREE_DISK_SPACE_STUB_DOCKER_EXIT (0 by default).
STUBS="$TEST_DIR/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/sudo" << 'STUB'
#!/usr/bin/env sh
echo "sudo $*" >> "$FREE_DISK_SPACE_STUB_LOG"
[ -z "${FREE_DISK_SPACE_STUB_SUDO_FAILS:-}" ] || exit 1
[ "$1" = '-n' ] && shift
exec "$@"
STUB
cat > "$STUBS/docker" << 'STUB'
#!/usr/bin/env sh
echo "docker $*" >> "$FREE_DISK_SPACE_STUB_LOG"
exit "${FREE_DISK_SPACE_STUB_DOCKER_EXIT:-0}"
STUB
chmod +x "$STUBS/sudo" "$STUBS/docker"

# hosted_agent <root>: a fixture of what a hosted Ubuntu image carries, under <root>.
hosted_agent() {
  local root="$1" path
  for path in usr/local/lib/android/sdk/platforms usr/share/dotnet/sdk/10.0.100 \
    usr/share/dotnet/sdk-manifests/10.0.100 usr/share/dotnet/packs/Microsoft.NETCore.App.Ref \
    usr/share/dotnet/templates/10.0.0 usr/share/dotnet/host/fxr/10.0.0 \
    usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.0 opt/ghc/9.14.1 usr/local/.ghcup/bin \
    usr/share/swift/usr/bin opt/hostedtoolcache/CodeQL/2.27.4 opt/hostedtoolcache/go/1.27.4; do
    mkdir -p "$root/$path" || return 1
    printf 'fixture\n' > "$root/$path/file"
  done
  printf '#!/bin/sh\n' > "$root/usr/share/dotnet/dotnet"
}

# free <root> <env assignment>...: runs the script against <root>, as a user who is not root, and
# prints its exit status; its output goes to $TEST_DIR/run.log and the stubs' calls to
# $TEST_DIR/calls.log.
free() {
  local root="$1" status=0
  shift
  : > "$TEST_DIR/calls.log"
  env -u AGENT_TOOLSDIRECTORY PATH="$STUBS:$PATH" FREE_DISK_SPACE_ROOT="$root" \
    FREE_DISK_SPACE_PATH="$TEST_DIR" FREE_DISK_SPACE_STUB_LOG="$TEST_DIR/calls.log" "$@" \
    sh "$RUN_SH" > "$TEST_DIR/run.log" 2>&1 || status=$?
  echo "$status"
}

echo "Testing the Go test job's disk clean-up..."

echo ""
echo "Test 1: on a hosted agent, what a Go job never uses is removed and the disk usage logged"
# given
AGENT="$TEST_DIR/agent"
hosted_agent "$AGENT" || exit 1

# when
STATUS="$(free "$AGENT")"

# then
assert_equals "the script succeeds" "0" "$STATUS"
for gone in usr/local/lib/android usr/share/dotnet/sdk usr/share/dotnet/sdk-manifests \
  usr/share/dotnet/packs usr/share/dotnet/templates opt/ghc usr/local/.ghcup usr/share/swift \
  opt/hostedtoolcache/CodeQL; do
  assert_true "$gone is removed" "[ ! -e '$AGENT/$gone' ]"
done
assert_true "the rest of the tool cache stays" "[ -e '$AGENT/opt/hostedtoolcache/go/1.27.4/file' ]"
assert_true "the pre-pulled Docker images are pruned" \
  "grep -qx 'docker image prune --all --force' '$TEST_DIR/calls.log'"
assert_true "the disk usage is logged before" "grep -q '^Disk usage of $TEST_DIR before freeing space:' '$TEST_DIR/run.log'"
assert_true "and after" "grep -q '^Disk usage of $TEST_DIR after freeing space (.* freed in all):' '$TEST_DIR/run.log'"
assert_equals "as df -h prints it, twice" "2" "$(grep -c '^Filesystem' "$TEST_DIR/run.log")"
assert_true "what each removal freed is logged" "grep -q '^Android SDK: removed, [0-9.]* [MG]iB freed.' '$TEST_DIR/run.log'"

echo ""
echo "Test 2: the .NET runtime the coverage publication needs stays"
for kept in usr/share/dotnet/dotnet usr/share/dotnet/host/fxr/10.0.0 \
  usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.0; do
  assert_true "$kept stays" "[ -e '$AGENT/$kept' ]"
done

echo ""
echo "Test 3: the removals run as root, through sudo -n -- which never waits for a password -- unless the job is root"
if [ "$(id -u)" -eq 0 ]; then
  assert_true "as root, no removal goes through sudo" "! grep -q '^sudo ' '$TEST_DIR/calls.log'"
else
  assert_true "every removal goes through sudo -n" \
    "grep -q '^sudo -n rm -rf -- $AGENT/usr/local/lib/android\$' '$TEST_DIR/calls.log'"
  assert_equals "and nothing calls sudo without -n" "0" "$(grep '^sudo ' "$TEST_DIR/calls.log" | grep -vc '^sudo -n ')"
fi

echo ""
echo "Test 4: a path the image does not carry is skipped, and a failure does not fail the job"
# given
EMPTY="$TEST_DIR/empty"
mkdir -p "$EMPTY"

# when
STATUS="$(free "$EMPTY")"

# then
assert_equals "the script succeeds on an image that carries none of them" "0" "$STATUS"
assert_true "it says there was nothing to remove" "grep -q '^Swift: not on this agent, nothing to remove.' '$TEST_DIR/run.log'"
assert_true "and calls no sudo" "! grep -q '^sudo ' '$TEST_DIR/calls.log'"

# A removal fails through the stub sudo, which a job running as root never calls.
if [ "$(id -u)" -ne 0 ]; then
  # given
  STUCK="$TEST_DIR/stuck"
  hosted_agent "$STUCK" || exit 1

  # when
  STATUS="$(free "$STUCK" FREE_DISK_SPACE_STUB_SUDO_FAILS=1 FREE_DISK_SPACE_STUB_DOCKER_EXIT=1)"

  # then
  assert_equals "the script succeeds when sudo and docker fail" "0" "$STATUS"
  assert_true "it reports the removal it could not make" \
    "grep -q '^WARNING: Android SDK: could not remove $STUCK/usr/local/lib/android; it stays.' '$TEST_DIR/run.log'"
  assert_true "and the prune it could not make" "grep -q '^WARNING: Pre-pulled Docker images: docker could not prune them' '$TEST_DIR/run.log'"
  assert_true "and the path stays" "[ -e '$STUCK/usr/local/lib/android/sdk/platforms/file' ]"
fi

echo ""
echo "Test 5: the templates forward FREE_DISK_SPACE and run the script only when it is true"
# The templates are read with mikefarah/yq, resolved the way every script here resolves it.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"
. "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"
YQ=""
if ! resolve_yq "$TEST_DIR/yqbin"; then
  echo -e "${RED}  FAIL: could not resolve mikefarah/yq, so the templates could not be read${NC}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  FORWARDED='${{ parameters.FREE_DISK_SPACE }}'
  CONDITION='${{ if eq(parameters.FREE_DISK_SPACE, true) }}'
  declared() {
    "$YQ" eval '.parameters[] | select(.name == "FREE_DISK_SPACE") | .type + "|" + (.default | tostring)' "$1"
  }

  # when
  ENTRY_DECLARED="$(declared "$AZURE/go-docker.yaml")"
  ENTRY_FORWARDED="$("$YQ" eval '.stages[] | select(.template == "stages/30-tests/go.yaml") | .parameters.FREE_DISK_SPACE' "$AZURE/go-docker.yaml")"
  STAGE_DECLARED="$(declared "$AZURE/stages/30-tests/go.yaml")"
  STAGE_FORWARDED="$("$YQ" eval '.stages[].jobs[] | select(.job == "test_all") | .steps[] | select(.template == "../../abstracts/test.yaml") | .parameters.FREE_DISK_SPACE' "$AZURE/stages/30-tests/go.yaml")"
  JOB_DECLARED="$(declared "$AZURE/abstracts/test.yaml")"
  # One line per step of the test job, in order: a template's path, a step's display name, or the
  # condition of a conditional block followed by the scripts it runs.
  JOB_STEPS="$("$YQ" eval '.steps[] | (.template // .displayName // (to_entries | .[0] | .key + " -> " + ([.value[].script] | join(","))))' "$AZURE/abstracts/test.yaml")"

  # then
  assert_equals "go-docker.yaml declares FREE_DISK_SPACE, a boolean defaulting to false" 'boolean|false' "$ENTRY_DECLARED"
  assert_equals "go-docker.yaml forwards it to the tests stage" "$FORWARDED" "$ENTRY_FORWARDED"
  assert_equals "the tests stage declares it the same way" 'boolean|false' "$STAGE_DECLARED"
  assert_equals "the tests stage forwards it to the test job's steps" "$FORWARDED" "$STAGE_FORWARDED"
  assert_equals "the test job's steps declare it the same way" 'boolean|false' "$JOB_DECLARED"
  assert_equals "the script runs only when it is true, after the Go set-up and before the tests" \
    "go.yaml
$CONDITION -> \$(Scripts.Directory)/global/scripts/languages/golang/free-disk-space/run.sh
Run Tests" "$(printf '%s\n' "$JOB_STEPS" | head -3)"
fi

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
