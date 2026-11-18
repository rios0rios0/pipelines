#!/usr/bin/env bash
# Regression test for how the gitleaks runner -- and every script that needs git to work in a
# directory another user owns -- marks it trusted: `git_trust_directory` in
# global/scripts/shared/git-config.sh, which global/scripts/tools/gitleaks/run.sh and the Dart
# runners' Flutter SDK use.
#
# Git refuses a repository owned by another user (`detected dubious ownership`) unless the
# directory is listed in `safe.directory`. The gitleaks runner used to append the project to the
# GLOBAL configuration on every run: on a CI runner that is the job's own configuration, but on a
# developer's machine it is `~/.gitconfig`, which kept every directory ever scanned. So:
#   1. on a CI runner (`CI`, or `TF_BUILD` on Azure DevOps) the directory is added to the global
#      configuration once, however often it is asked for, and the entries already there are kept
#   2. on a developer's machine the global configuration is never written: the directory reaches
#      git through the environment (`GIT_CONFIG_COUNT`/`KEY`/`VALUE`), once, beside the pairs a
#      project's `config.sh` exported, and a git started from there trusts it
#   3. end to end, the real runner -- with a stub `gitleaks` that runs `git log` in the source, as
#      the real one does -- scans a repository git takes for another user's on both kinds of
#      machine, and only the CI run writes the global configuration
#
# Every check runs against a throwaway global configuration (GIT_CONFIG_GLOBAL), never the machine's.
# `GIT_TEST_ASSUME_DIFFERENT_OWNER`, git's own test switch, makes a repository look like another
# user's without changing who owns it.
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
HELPER="$ROOT/global/scripts/shared/git-config.sh"
RUNNER="$ROOT/global/scripts/tools/gitleaks/run.sh"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
CHECKOUT="$WORK/checkout"
mkdir -p "$CHECKOUT"

check() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAIL${NC} $description (expected=$expected, actual=$actual)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

entries() { git config --global --get-all safe.directory 2> /dev/null | grep -Fcx -- "$1" || true; }
total() { git config --global --get-all safe.directory 2> /dev/null | wc -l | tr -d ' '; }

# trust <env assignment>...: runs `git_trust_directory "$CHECKOUT"` twice in a POSIX shell, from the
# checkout, with CI and TF_BUILD unset unless the arguments set one, and prints the GIT_CONFIG_*
# pairs it left in the environment, one `key=value` per line.
trust() {
  (
    cd "$CHECKOUT" || exit 1
    env -u CI -u TF_BUILD "$@" sh -c '
      . "$1"
      git_trust_directory "$2"
      git_trust_directory "$2"
      i=0
      while [ "$i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
        eval "printf \"%s=%s\n\" \"\$GIT_CONFIG_KEY_$i\" \"\$GIT_CONFIG_VALUE_$i\""
        i=$((i + 1))
      done
    ' sh "$HELPER" "$CHECKOUT"
  )
}

echo "=== git_trust_directory on a CI runner ==="
for marker in CI=true TF_BUILD=True; do
  # given
  : > "$GIT_CONFIG_GLOBAL"

  # when
  PAIRS="$(trust "$marker")"

  # then
  check "$marker: the checkout is trusted in the global configuration" "1" "$(entries "$CHECKOUT")"
  check "$marker: asking again adds nothing" "1" "$(total)"
  check "$marker: nothing is handed through the environment" "" "$PAIRS"
done

# given
: > "$GIT_CONFIG_GLOBAL"
git config --global --add safe.directory /some/other/checkout

# when
trust CI=true > /dev/null

# then
check "another trusted directory is kept" "1" "$(entries /some/other/checkout)"
check "and the checkout is added beside it once" "2" "$(total)"

echo ""
echo "=== git_trust_directory on a developer's machine ==="
# given
printf '[user]\n\tname = Developer\n' > "$GIT_CONFIG_GLOBAL"
BEFORE="$(cksum < "$GIT_CONFIG_GLOBAL")"

# when
PAIRS="$(trust)"

# then
check "the global configuration is not written" "$BEFORE" "$(cksum < "$GIT_CONFIG_GLOBAL")"
check "the checkout reaches git through the environment, once" "safe.directory=$CHECKOUT" "$PAIRS"

# given: the pairs a project's config.sh exported before the runner started
# when
PAIRS="$(trust GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://example.invalid/mirror.insteadOf \
  GIT_CONFIG_VALUE_0=https://example.invalid/origin)"

# then
check "the pairs already exported are kept, and the checkout is added after them" \
  "url.https://example.invalid/mirror.insteadOf=https://example.invalid/origin
safe.directory=$CHECKOUT" "$PAIRS"

echo ""
echo "=== the gitleaks runner, end to end ==="
# The fixture repository, committed with no hook: a developer's global core.hooksPath is not part
# of what this suite tests.
REPO="$WORK/repo"
mkdir -p "$REPO" "$WORK/no-hooks"
git -c init.defaultBranch=main init -q "$REPO" || exit 1
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md || exit 1
git -c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath="$WORK/no-hooks" \
  -C "$REPO" commit -q -m fixture || exit 1

if GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git -C "$REPO" rev-parse HEAD > /dev/null 2>&1; then
  echo -e "${YELLOW}SKIP${NC} this git does not honour GIT_TEST_ASSUME_DIFFERENT_OWNER, so no repository looks like another user's"
else
  check "git refuses the fixture while it looks like another user's" "refused" \
    "$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git -C "$REPO" rev-parse HEAD > /dev/null 2>&1 || echo refused)"

  # A stub `gitleaks` on the runner's own PATH entry (`$HOME/.local/bin`, which cleanup.sh puts
  # first): it reports the pinned version, so the runner installs nothing, and `detect` runs
  # `git log` in the source as the real one does, failing when git refuses it.
  . "$ROOT/global/scripts/shared/pinned-versions.sh"
  export HOME="$WORK/home"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/gitleaks" << STUB
#!/usr/bin/env sh
if [ "\$1" = version ]; then
  echo '${GITLEAKS_VERSION#v}'
  exit 0
fi
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --source) source_dir="\$2"; shift ;;
    --report-path) report="\$2"; shift ;;
  esac
  shift
done
git -C "\$source_dir" log --oneline -1 > /dev/null || exit 3
echo '[]' > "\$report"
STUB
  chmod +x "$HOME/.local/bin/gitleaks"

  # scan <env assignment>...: runs the runner in the fixture, as another user's repository, and
  # prints its exit status; its output goes to $WORK/scan.log.
  scan() {
    local status=0
    (
      cd "$REPO" || exit 1
      env -u CI -u TF_BUILD -u GITHUB_EVENT_NAME -u CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
        -u SYSTEM_PULLREQUEST_TARGETBRANCH -u GIT_CONFIG_COUNT -u SCRIPTS_DIR \
        GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$@" "$RUNNER"
    ) > "$WORK/scan.log" 2>&1 || status=$?
    echo "$status"
  }

  # given
  printf '[user]\n\tname = Developer\n' > "$GIT_CONFIG_GLOBAL"
  BEFORE="$(cksum < "$GIT_CONFIG_GLOBAL")"

  # when
  STATUS="$(scan)"

  # then
  [[ "$STATUS" == "0" ]] || cat "$WORK/scan.log"
  check "on a developer's machine the scan runs git in the repository" "0" "$STATUS"
  check "and leaves the global configuration as it was" "$BEFORE" "$(cksum < "$GIT_CONFIG_GLOBAL")"

  # given
  : > "$GIT_CONFIG_GLOBAL"

  # when
  STATUS="$(scan CI=true)"

  # then
  [[ "$STATUS" == "0" ]] || cat "$WORK/scan.log"
  check "on a CI runner the scan runs git in the repository" "0" "$STATUS"
  check "and trusts the checkout in the global configuration, once" "1" "$(entries "$REPO")"
fi

echo ""
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
