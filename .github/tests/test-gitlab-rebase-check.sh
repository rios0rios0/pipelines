#!/usr/bin/env bash
# The rebase check of `quality:basic-checks` on GitLab
# (gitlab/global/stages/10-code-check/basic-checks.yaml).
#
# An ordinary merge request pipeline runs on the merge request's own commit, so the check can
# compare HEAD with the target branch. A merged results pipeline, and a merge train, runs instead on
# the merge commit GitLab prepares, `refs/merge-requests/<iid>/merge`, and a merge commit always
# contains the target branch: judged by HEAD, every merge request passed there, rebased or not. The
# check therefore judges `CI_MERGE_REQUEST_SOURCE_BRANCH_SHA`, which GitLab sets in those pipelines
# only, and HEAD otherwise -- the flaw `test-azure-devops-rebase-check.sh` pins on Azure DevOps.
#
# The job's real script is extracted from the template and run under `sh -e`, as the runner runs
# it, in clones that reproduce both checkouts: a merge request behind its target must fail and a
# rebased one must pass in either kind of pipeline, and every path where the check cannot reach a
# verdict must fail rather than pass. No consumer runs these templates on GitLab yet, so this suite
# is the check's only verification.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
TEMPLATE="$REPO_ROOT/gitlab/global/stages/10-code-check/basic-checks.yaml"

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

SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

. "$REPO_ROOT/global/scripts/shared/pinned-versions.sh"
. "$REPO_ROOT/global/scripts/shared/verify-download.sh"
. "$REPO_ROOT/global/scripts/shared/resolve-yq.sh"
YQ=""
resolve_yq "$SANDBOX/yqbin" || { echo -e "${RED}could not resolve mikefarah/yq, so no case can run${NC}"; exit 1; }

STEP="$SANDBOX/job.sh"
"$YQ" eval '.["quality:basic-checks"].script[0]' "$TEMPLATE" > "$STEP"
if [[ ! -s "$STEP" || "$(head -c 4 "$STEP")" == 'null' ]]; then
  echo -e "${RED}could not extract the quality:basic-checks script from $TEMPLATE${NC}"
  exit 1
fi
mkdir -p "$SANDBOX/home" || exit 1

REAL_GIT="$(command -v git)" || exit 1
fixture_git() { "$REAL_GIT" -c user.name=fixture -c user.email=fixture@example.test -c commit.gpgsign=false "$@"; }

# An origin whose `main` holds c1 and c2, with two merge requests: `feat/behind` forked from c1, so
# it is one commit behind, and `feat/rebased` forked from c2. Each carries a changelog fragment, so
# the check reaches a verdict on the rebase alone. Their merged results refs are built the way GitLab
# builds them: the target branch as the first parent, the merge request's commit as the second.
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
"$REAL_GIT" init -q --bare "$ORIGIN" || exit 1
"$REAL_GIT" init -q -b main "$SEED" || exit 1
mkdir -p "$SEED/.changes/unreleased" || exit 1
: > "$SEED/.changes/unreleased/.gitkeep"
echo 'one' > "$SEED/file.txt"
fixture_git -C "$SEED" add -A && fixture_git -C "$SEED" commit -q -m 'c1' || exit 1
fixture_git -C "$SEED" branch 'feat/behind' || exit 1
echo 'two' >> "$SEED/file.txt"
fixture_git -C "$SEED" commit -q -am 'c2' || exit 1
fixture_git -C "$SEED" branch 'feat/rebased' || exit 1
for branch in 'feat/rebased' 'feat/behind'; do
  fixture_git -C "$SEED" checkout -q "$branch" || exit 1
  echo 'kind: Fixed' > "$SEED/.changes/unreleased/${branch#feat/}.yaml"
  fixture_git -C "$SEED" add -A && fixture_git -C "$SEED" commit -q -m "change on $branch" || exit 1
done
for mr in '1:feat/behind' '2:feat/rebased'; do
  fixture_git -C "$SEED" checkout -q --detach main || exit 1
  fixture_git -C "$SEED" merge -q --no-ff -m "Merge branch '${mr#*:}' into 'main'" "${mr#*:}" || exit 1
  fixture_git -C "$SEED" update-ref "refs/merge-requests/${mr%%:*}/merge" HEAD || exit 1
done
fixture_git -C "$SEED" push -q "$ORIGIN" main 'feat/behind' 'feat/rebased' 'refs/merge-requests/*:refs/merge-requests/*' || exit 1
BEHIND_SHA="$("$REAL_GIT" -C "$SEED" rev-parse 'feat/behind')"
REBASED_SHA="$("$REAL_GIT" -C "$SEED" rev-parse 'feat/rebased')"
MAIN_SHA="$("$REAL_GIT" -C "$SEED" rev-parse 'main')"

# checkout <dir> <ref>: what the runner does with `GIT_DEPTH: 0` -- every branch fetched, plus the
# ref the pipeline runs on, which is then checked out detached.
checkout() {
  "$REAL_GIT" init -q "$1" || return 1
  "$REAL_GIT" -C "$1" remote add origin "$ORIGIN" || return 1
  "$REAL_GIT" -C "$1" fetch -q --force --no-tags --prune origin '+refs/heads/*:refs/remotes/origin/*' "+$2:refs/pipeline/head" || return 1
  "$REAL_GIT" -C "$1" checkout -q --force --detach 'refs/pipeline/head'
}

# run_job <dir> [NAME=value ...]: runs the job in <dir> with the variables of a merge request
# pipeline into `main`, overridden or extended by the arguments. Sets RC and OUT.
run_job() {
  local dir="$1"
  shift
  OUT="$(cd "$dir" || exit 1
    env -i PATH="$PATH" HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      CI_DEFAULT_BRANCH='main' CI_MERGE_REQUEST_IID='1' CI_MERGE_REQUEST_TARGET_BRANCH_NAME='main' "$@" \
      sh -e "$STEP" 2>&1)"
  RC=$?
}

echo "=== GitLab rebase check ==="

echo ""
echo "Test 1: a merge request pipeline judges HEAD, the merge request's own commit"
# given
checkout "$SANDBOX/mr1" 'refs/heads/feat/behind' || exit 1
checkout "$SANDBOX/mr2" 'refs/heads/feat/rebased' || exit 1
# when
run_job "$SANDBOX/mr1" CI_MERGE_REQUEST_SOURCE_BRANCH_NAME='feat/behind'
# then
check "a branch behind the target fails" exited 1
check "naming it as not rebased" has "$OUT" "ERROR: Branch is NOT rebased on top of 'main'."
check "one commit behind" has "$OUT" "The branch is 1 commit(s) behind."
# when
run_job "$SANDBOX/mr2" CI_MERGE_REQUEST_SOURCE_BRANCH_NAME='feat/rebased'
# then
check "a rebased branch passes" exited 0
check "as rebased" has "$OUT" "Branch is up-to-date with 'main'. No rebase needed."
check "on to the changelog check" has "$OUT" "Found changelog fragment(s):"

echo ""
echo "Test 2: a merged results pipeline judges CI_MERGE_REQUEST_SOURCE_BRANCH_SHA, not its merge commit"
# given the merge commits GitLab prepares, each of which contains main
checkout "$SANDBOX/mr1-merged" 'refs/merge-requests/1/merge' || exit 1
checkout "$SANDBOX/mr2-merged" 'refs/merge-requests/2/merge' || exit 1
# when
run_job "$SANDBOX/mr1-merged" CI_MERGE_REQUEST_SOURCE_BRANCH_NAME='feat/behind' CI_MERGE_REQUEST_SOURCE_BRANCH_SHA="$BEHIND_SHA"
# then
check "a branch behind the target fails" exited 1
check "one commit behind" has "$OUT" "The branch is 1 commit(s) behind."
# when
run_job "$SANDBOX/mr2-merged" CI_MERGE_REQUEST_SOURCE_BRANCH_NAME='feat/rebased' CI_MERGE_REQUEST_SOURCE_BRANCH_SHA="$REBASED_SHA"
# then
check "a rebased branch passes" exited 0
check "as rebased" has "$OUT" "No rebase needed."
check "on to the changelog check" has "$OUT" "Found changelog fragment(s):"

echo ""
echo "Test 3: a fetch that fails fails the check"
# given a remote that cannot be reached
checkout "$SANDBOX/mr1-offline" 'refs/heads/feat/behind' || exit 1
"$REAL_GIT" -C "$SANDBOX/mr1-offline" remote set-url origin "$SANDBOX/no-such-remote.git" || exit 1
# when
run_job "$SANDBOX/mr1-offline" CI_MERGE_REQUEST_SOURCE_BRANCH_NAME='feat/behind'
# then
check "the job fails" exited 1
check "saying it could not fetch the target" has "$OUT" "ERROR: could not fetch 'main' from origin, so the rebase check cannot run."
# when
run_job "$SANDBOX/mr2" CI_MERGE_REQUEST_TARGET_BRANCH_NAME='no-such-branch'
# then
check "a target branch the remote does not have fails too" exited 1
check "the same way" has "$OUT" "ERROR: could not fetch 'no-such-branch' from origin"

echo ""
echo "Test 4: a source commit that cannot be resolved fails the check"
# when
run_job "$SANDBOX/mr2-merged" CI_MERGE_REQUEST_SOURCE_BRANCH_SHA='0123456789abcdef0123456789abcdef01234567'
# then
check "an unknown source commit fails" exited 1
check "naming it" has "$OUT" "ERROR: could not resolve the merge request's source commit ('0123456789abcdef0123456789abcdef01234567')"

echo ""
echo "Test 5: the default branch's own pipeline is already merged, so it skips the checks"
# given the job's other rule: a pipeline on the default branch, with no merge request
checkout "$SANDBOX/main" 'refs/heads/main' || exit 1
# when
run_job "$SANDBOX/main" CI_MERGE_REQUEST_IID='' CI_MERGE_REQUEST_TARGET_BRANCH_NAME=''
# then
check "the job passes" exited 0
check "saying the commit is part of main" has "$OUT" "Branch head ${MAIN_SHA} is already part of 'main' (likely merged)."
check "without judging it" lacks "$OUT" "=== Changelog Check ==="

echo ""
echo "Test 6: a source commit already merged into the target skips the checks"
# given the rebased merge request merged into main after its pipeline started
fixture_git -C "$SEED" push -q "$ORIGIN" 'feat/rebased:main' || exit 1
# when
run_job "$SANDBOX/mr2-merged" CI_MERGE_REQUEST_SOURCE_BRANCH_SHA="$REBASED_SHA"
# then
check "the job passes" exited 0
check "saying the branch is merged" has "$OUT" "is already part of 'main' (likely merged). Skipping all basic checks."
check "without judging it" lacks "$OUT" "=== Changelog Check ==="

echo ""
echo "=== Results ==="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
