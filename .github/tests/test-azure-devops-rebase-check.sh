#!/usr/bin/env bash
# The rebase check of `quality:basic-checks` on Azure DevOps
# (azure-devops/global/stages/10-code-check/basic-checks.yaml).
#
# An Azure DevOps pull request build checks out the merge commit the service prepares,
# `refs/pull/<id>/merge`, whose first parent is the target branch and whose second is the pull
# request's source commit. The check compared that merge commit with the target branch, and a merge
# commit always contains its first parent, so every pull request passed, rebased or not. Its fetch
# of the target branch also failed on every build, because the checkout keeps no credentials, and
# the step carries no `set -e`, so the failure was ignored too.
#
# The step's real script is extracted from the template and run the way the agent runs it
# (`bash --noprofile --norc <file>`), in a clone that reproduces the agent's checkout of a merge
# ref: up-to-date and cleanly mergeable branches pass, and conflicts and errors fail.
# A `git` wrapper records each call so the cases can pin how the job's token reaches the fetch.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
TEMPLATE="$REPO_ROOT/azure-devops/global/stages/10-code-check/basic-checks.yaml"
TOKEN='fixture-token-placeholder'

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}  PASS: $1${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# check <description> <command> [<argument> ...]: passes when the command succeeds; a failure
# prints the last run's exit status and output.
check() {
  local description="$1"
  shift
  if "$@"; then
    pass "$description"
  else
    fail "$description"
    printf '%s\n' "rc=${RC:-unset}" "${OUT:-}" | sed 's/^/        /'
  fi
}
exited() { [[ "$RC" -eq "$1" ]]; }
has() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
absent() { ! grep -qE -- "$1" "$2"; }

SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

. "$REPO_ROOT/global/scripts/shared/pinned-versions.sh"
. "$REPO_ROOT/global/scripts/shared/verify-download.sh"
. "$REPO_ROOT/global/scripts/shared/resolve-yq.sh"
YQ=""
resolve_yq "$SANDBOX/yqbin" || { echo -e "${RED}could not resolve mikefarah/yq, so no case can run${NC}"; exit 1; }

STEP_SELECTOR='.jobs[] | select(.job == "quality_basic_checks") | .steps[] | select(.displayName == "Run basic checks")'
STEP="$SANDBOX/step.sh"
"$YQ" eval "$STEP_SELECTOR | .script" "$TEMPLATE" > "$STEP"
if [[ ! -s "$STEP" || "$(head -c 4 "$STEP")" == 'null' ]]; then
  echo -e "${RED}could not extract the 'Run basic checks' script from $TEMPLATE${NC}"
  exit 1
fi

# Every git call the step makes goes through this wrapper: it records the arguments, and the value
# of the variable a `--config-env` names, then runs the real git.
REAL_GIT="$(command -v git)" || exit 1
mkdir -p "$SANDBOX/bin" "$SANDBOX/home" || exit 1
cat > "$SANDBOX/bin/git" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REBASE_TEST_CALLS"
for arg in "$@"; do
  case "$arg" in
    --config-env=*=*) name="${arg##*=}"; printf '%s=%s\n' "${arg#--config-env=}" "${!name-}" >> "$REBASE_TEST_HEADERS" ;;
  esac
done
if [[ "${REBASE_TEST_FAIL_MERGE:-}" == '1' ]]; then
  case "$*" in
    'merge-tree --write-tree '*) exit 128 ;;
    *' merge --no-commit --no-ff '*) exit 1 ;;
  esac
fi
exec "$REBASE_TEST_REAL_GIT" "$@"
EOF
chmod +x "$SANDBOX/bin/git" || exit 1

fixture_git() { "$REAL_GIT" -c user.name=fixture -c user.email=fixture@example.test -c commit.gpgsign=false "$@"; }

# An origin whose `main` holds c1 and c2, with two pull requests: `feat/behind` forked from c1, so
# it is one commit behind, and `feat/rebased` forked from c2. Each carries a changelog fragment, so
# the check reaches a verdict on the rebase alone. Their merge refs are built the way Azure DevOps
# builds them: the target branch as the first parent, the source commit as the second.
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
"$REAL_GIT" init -q --bare "$ORIGIN" || exit 1
"$REAL_GIT" init -q -b main "$SEED" || exit 1
mkdir -p "$SEED/.changes/unreleased" || exit 1
: > "$SEED/.changes/unreleased/.gitkeep"
printf 'line %s\n' {1..12} > "$SEED/file.txt"
fixture_git -C "$SEED" add -A && fixture_git -C "$SEED" commit -q -m 'c1' || exit 1
fixture_git -C "$SEED" branch 'feat/behind' || exit 1
sed -i '1s/^/main: /' "$SEED/file.txt" || exit 1
fixture_git -C "$SEED" commit -q -am 'c2' || exit 1
fixture_git -C "$SEED" branch 'feat/rebased' || exit 1
for branch in 'feat/rebased' 'feat/behind'; do
  fixture_git -C "$SEED" checkout -q "$branch" || exit 1
  if [[ "$branch" == 'feat/behind' ]]; then
    sed -i '$s/^/source: /' "$SEED/file.txt" || exit 1
  fi
  echo 'kind: Fixed' > "$SEED/.changes/unreleased/${branch#feat/}.yaml"
  fixture_git -C "$SEED" add -A && fixture_git -C "$SEED" commit -q -m "change on $branch" || exit 1
done
for pr in '1:feat/behind' '2:feat/rebased'; do
  fixture_git -C "$SEED" checkout -q --detach main || exit 1
  fixture_git -C "$SEED" merge -q --no-ff -m "Merge pull request ${pr%%:*} from ${pr#*:} into main" "${pr#*:}" || exit 1
  fixture_git -C "$SEED" update-ref "refs/pull/${pr%%:*}/merge" HEAD || exit 1
done
fixture_git -C "$SEED" push -q "$ORIGIN" main 'feat/behind' 'feat/rebased' 'refs/pull/*:refs/pull/*' || exit 1
BEHIND_SHA="$("$REAL_GIT" -C "$SEED" rev-parse 'feat/behind')"
REBASED_SHA="$("$REAL_GIT" -C "$SEED" rev-parse 'feat/rebased')"

# checkout <dir> <ref>: what the agent does for a pull request build -- every branch and the merge
# ref fetched with no credentials kept, then the merge ref checked out detached.
checkout() {
  "$REAL_GIT" init -q "$1" || return 1
  "$REAL_GIT" -C "$1" remote add origin "$ORIGIN" || return 1
  "$REAL_GIT" -C "$1" fetch -q --force --no-tags --prune origin '+refs/heads/*:refs/remotes/origin/*' "+$2:refs/remotes/${2#refs/}" || return 1
  "$REAL_GIT" -C "$1" checkout -q --force "refs/remotes/${2#refs/}"
}

checkout_state() {
  "$REAL_GIT" -C "$1" rev-parse HEAD &&
    "$REAL_GIT" -C "$1" diff --binary HEAD &&
    "$REAL_GIT" -C "$1" diff --cached --binary &&
    "$REAL_GIT" -C "$1" worktree list --porcelain
}

# run_step <dir> [NAME=value ...]: runs the step in <dir> with the variables of a pull request build
# into `main` from an Azure Repos repository, overridden or extended by the arguments. Sets RC, OUT,
# CALLS (every git call) and HEADERS (every configuration a `--config-env` passed).
run_step() {
  local dir="$1"
  shift
  : > "$SANDBOX/calls"
  : > "$SANDBOX/headers"
  OUT="$(cd "$dir" || exit 1
    env -i PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      REBASE_TEST_CALLS="$SANDBOX/calls" REBASE_TEST_HEADERS="$SANDBOX/headers" REBASE_TEST_REAL_GIT="$REAL_GIT" \
      BUILD_REPOSITORY_PROVIDER='TfsGit' SYSTEM_ACCESSTOKEN="$TOKEN" \
      SYSTEM_PULLREQUEST_TARGETBRANCH='refs/heads/main' "$@" \
      bash --noprofile --norc "$STEP" 2>&1)"
  RC=$?
  CALLS="$(cat "$SANDBOX/calls")"
  HEADERS="$(cat "$SANDBOX/headers")"
}

echo "=== Azure DevOps rebase check ==="

echo ""
echo "Test 1: a source branch behind the target passes when edits to the same file do not overlap"
# given
checkout "$SANDBOX/pr1" 'refs/pull/1/merge' || exit 1
PR1_STATE="$(checkout_state "$SANDBOX/pr1")" || exit 1
# when
run_step "$SANDBOX/pr1" SYSTEM_PULLREQUEST_SOURCEBRANCH='refs/heads/feat/behind' SYSTEM_PULLREQUEST_SOURCECOMMITID="$BEHIND_SHA"
# then
check "the step passes" exited 0
check "one commit behind and merges cleanly" has "$OUT" "Branch is 1 commit(s) behind 'main' but merges cleanly. No rebase needed."
check "on to the changelog check" has "$OUT" "Found changelog fragment(s):"
check "checkout unchanged and no worktree left behind" test "$(checkout_state "$SANDBOX/pr1")" = "$PR1_STATE"

echo ""
echo "Test 2: a rebased source branch passes"
# given
checkout "$SANDBOX/pr2" 'refs/pull/2/merge' || exit 1
# when
run_step "$SANDBOX/pr2" SYSTEM_PULLREQUEST_SOURCEBRANCH='refs/heads/feat/rebased' SYSTEM_PULLREQUEST_SOURCECOMMITID="$REBASED_SHA"
# then
check "the step passes" exited 0
check "as rebased" has "$OUT" "Branch is up-to-date with 'main'. No rebase needed."
check "on to the changelog check" has "$OUT" "Found changelog fragment(s):"

echo ""
echo "Test 3: without the agent's source commit, the merge commit's second parent is judged"
# given the two checkouts above, and no SYSTEM_PULLREQUEST_SOURCECOMMITID
# when
run_step "$SANDBOX/pr1" SYSTEM_PULLREQUEST_SOURCEBRANCH='refs/heads/feat/behind'
# then
check "the branch behind the target still passes" exited 0
check "as one commit behind and merges cleanly" has "$OUT" "Branch is 1 commit(s) behind 'main' but merges cleanly. No rebase needed."
# when
run_step "$SANDBOX/pr2" SYSTEM_PULLREQUEST_SOURCEBRANCH='refs/heads/feat/rebased'
# then
check "the rebased branch still passes" exited 0
check "as rebased" has "$OUT" "No rebase needed."

echo ""
echo "Test 4: the job's token reaches the fetch through the environment only"
# given the checkout of the rebased pull request
# when
run_step "$SANDBOX/pr2" SYSTEM_PULLREQUEST_SOURCECOMMITID="$REBASED_SHA"
# then
check "the fetch names the header's variable, not its value" has "$CALLS" \
  '--config-env=http.extraheader=REBASE_CHECK_AUTH_HEADER fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main'
check "and the variable holds the job's token as a bearer header" \
  test "$HEADERS" = "http.extraheader=REBASE_CHECK_AUTH_HEADER=AUTHORIZATION: bearer $TOKEN"
check "no git command line carries the token" lacks "$CALLS" "$TOKEN"
# when
run_step "$SANDBOX/pr2" SYSTEM_PULLREQUEST_SOURCECOMMITID="$REBASED_SHA" BUILD_REPOSITORY_PROVIDER='GitHub'
# then
check "a repository outside Azure Repos still passes" exited 0
check "fetched without the header, so the token reaches no other host" test -z "$HEADERS"
# shellcheck disable=SC2016  # the single-quoted `$(...)` is the template's expected TEXT, never an expansion
check "the step maps the token into its environment" \
  test "$("$YQ" eval "$STEP_SELECTOR | .env.SYSTEM_ACCESSTOKEN" "$TEMPLATE")" = '$(System.AccessToken)'
# shellcheck disable=SC2016  # a pattern for the template's text: a macro is substituted before bash runs
check "and reads the pull request through variables, never through \$(...) macros" \
  absent '\$\((System|Build)\.[A-Za-z.]+\)' "$STEP"

echo ""
echo "Test 5: a fetch that fails fails the check"
# given a remote that cannot be reached
checkout "$SANDBOX/pr1-offline" 'refs/pull/1/merge' || exit 1
"$REAL_GIT" -C "$SANDBOX/pr1-offline" remote set-url origin "$SANDBOX/no-such-remote.git" || exit 1
# when
run_step "$SANDBOX/pr1-offline" SYSTEM_PULLREQUEST_SOURCECOMMITID="$BEHIND_SHA"
# then
check "the step fails" exited 1
check "saying it could not fetch the target" has "$OUT" "ERROR: could not fetch 'main' from origin, so the rebase check cannot run."
# when
run_step "$SANDBOX/pr2" SYSTEM_PULLREQUEST_SOURCECOMMITID="$REBASED_SHA" SYSTEM_PULLREQUEST_TARGETBRANCH='refs/heads/no-such-branch'
# then
check "a target branch the remote does not have fails too" exited 1
check "the same way" has "$OUT" "ERROR: could not fetch 'no-such-branch' from origin"

echo ""
echo "Test 6: a source commit that cannot be resolved fails the check"
# when
run_step "$SANDBOX/pr2" SYSTEM_PULLREQUEST_SOURCECOMMITID='0123456789abcdef0123456789abcdef01234567'
# then
check "an unknown source commit fails" exited 1
check "naming it" has "$OUT" "ERROR: could not resolve the pull request's source commit ('0123456789abcdef0123456789abcdef01234567')"
# given a checkout that is not a merge commit
checkout "$SANDBOX/plain" 'refs/heads/feat/rebased' || exit 1
# when
run_step "$SANDBOX/plain"
# then
check "no source commit and no merge commit fails" exited 1
check "naming neither" has "$OUT" "source commit ('none')"

echo ""
echo "Test 7: a source commit already merged into the target skips the checks"
# given the rebased pull request completed into main after its build started
fixture_git -C "$SEED" push -q "$ORIGIN" 'feat/rebased:main' || exit 1
# when
run_step "$SANDBOX/pr2" SYSTEM_PULLREQUEST_SOURCECOMMITID="$REBASED_SHA"
# then
check "the step passes" exited 0
check "saying the branch is merged" has "$OUT" "is already part of 'main' (likely merged). Skipping all basic checks."
check "without judging it" lacks "$OUT" "=== Changelog Check ==="

echo ""
echo "Test 8: a textual conflict with the fetched target names the file and fails"
# The target advanced after Azure DevOps prepared a clean merge ref for PR 1.
fixture_git -C "$SEED" checkout -q 'feat/rebased' || exit 1
sed -i '$s/^/target: /' "$SEED/file.txt" || exit 1
fixture_git -C "$SEED" commit -q -am 'conflicting edit on main' || exit 1
fixture_git -C "$SEED" push -q "$ORIGIN" 'HEAD:main' || exit 1
run_step "$SANDBOX/pr1" SYSTEM_PULLREQUEST_SOURCECOMMITID="$BEHIND_SHA"
check "the step fails" exited 1
check "the branch conflicts with main" has "$OUT" "ERROR: Branch conflicts with 'main'."
check "the conflict report names file.txt" has "$OUT" $'Conflicted files:\nfile.txt'
check "the instructions say how to rebase" has "$OUT" "git rebase origin/main"
check "checkout unchanged and no worktree left behind" test "$(checkout_state "$SANDBOX/pr1")" = "$PR1_STATE"

echo ""
echo "Test 9: an error running the merge test fails the check"
run_step "$SANDBOX/pr1" SYSTEM_PULLREQUEST_SOURCECOMMITID="$BEHIND_SHA" REBASE_TEST_FAIL_MERGE=1
check "the step fails" exited 1
check "the check could not run the test" has "$OUT" "so the rebase check cannot run."
check "without reporting a conflict" lacks "$OUT" "ERROR: Branch conflicts with"
check "checkout unchanged and no worktree left behind" test "$(checkout_state "$SANDBOX/pr1")" = "$PR1_STATE"

echo ""
echo "=== Results ==="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
