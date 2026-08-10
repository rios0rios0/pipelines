#!/usr/bin/env sh

# Refuse to deploy a commit that has not passed the checks the project treats as
# its quality gate.
#
# This exists because of a hole that opens in a very common pipeline shape. A
# repository that runs its expensive jobs on `main` and then releases by tagging
# usually skips those jobs on the tag -- the commit is the same one that already
# passed, so repeating twenty minutes of linting and scanning buys nothing. The
# saving is real, but it rests on a premise nothing enforces: a tag can be cut
# from any commit, including one that never reached the default branch or one
# that landed red. Worse, a delivery job that `needs:` those skipped jobs still
# runs, because GitHub counts a skipped dependency as satisfied. The result is a
# release built and deployed with no gate at all, and nothing in the run looks
# wrong.
#
# Check runs are recorded against the COMMIT, not against the ref that triggered
# them, so the verdict from the default-branch push is still readable when the
# tag is pushed. Asserting it costs one API call and pins the exact commit --
# strictly more than re-running the suite on the tag would prove, for none of
# the time.
#
# GitHub-only by nature: check runs are a GitHub concept. GitLab and Azure
# DevOps expose the equivalent through their own pipeline-status APIs, and a
# sibling script can be added here when a consumer needs one.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="require-checks" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"

deploy_require_env "REQUIRE_CHECKS_NAMES" \
  "Newline-separated check-run names that must have succeeded, e.g. the delivery job's own \`needs:\` list."

REQUIRE_CHECKS_COMMIT="${REQUIRE_CHECKS_COMMIT:-${GITHUB_SHA:-}}"
REQUIRE_CHECKS_REPOSITORY="${REQUIRE_CHECKS_REPOSITORY:-${GITHUB_REPOSITORY:-}}"

deploy_require_env "REQUIRE_CHECKS_COMMIT" \
  "The commit to verify. Defaults to GITHUB_SHA inside GitHub Actions."
deploy_require_env "REQUIRE_CHECKS_REPOSITORY" \
  "The owner/repo to query. Defaults to GITHUB_REPOSITORY inside GitHub Actions."

for _rc_tool in gh jq; do
  if ! command -v "$_rc_tool" > /dev/null 2>&1; then
    echo "ERROR: '$_rc_tool' is required to read check runs but is not installed." >&2
    exit 1
  fi
done
unset _rc_tool

# `cleanup.sh` re-exports REPORT_PATH as the tool's own subdirectory, so the
# tool name must NOT be repeated here.
CHECKS_FILE="$REPORT_PATH/check-runs.json"

# A dry run resolves what would be asserted without calling the API, matching
# every other script in this family and keeping the validation harness offline.
if deploy_is_dry_run; then
  echo "DRY RUN: would require these checks on $REQUIRE_CHECKS_COMMIT:"
  printf '%s\n' "$REQUIRE_CHECKS_NAMES" | while IFS= read -r _rc_name; do
    [ -n "$_rc_name" ] && echo "  - $_rc_name"
  done
  exit 0
fi

if ! gh api --paginate "repos/$REQUIRE_CHECKS_REPOSITORY/commits/$REQUIRE_CHECKS_COMMIT/check-runs" \
  --jq '.check_runs[] | {name, conclusion}' | jq -s '.' > "$CHECKS_FILE"; then
  echo "ERROR: failed to read check runs for $REQUIRE_CHECKS_COMMIT." >&2
  echo "The job needs 'checks: read' permission and a token that can see this repository." >&2
  exit 1
fi

echo "Check runs recorded against $REQUIRE_CHECKS_COMMIT:"
jq -r '.[] | "  \(.conclusion // "pending")\t\(.name)"' "$CHECKS_FILE"

# Each name is required to have SUCCEEDED, rather than the whole commit being
# required to carry no failure. The negative form is wrong twice over: every
# workflow attaches its runs to the same commit, so an unrelated keep-alive ping
# would trip it, and a failed deploy from an earlier attempt would make the gate
# permanently refuse to retry the very deploy it guards. It is also too weak on
# its own, because a commit nobody ever tested carries no failures either.
#
# Split on newline with `for` rather than piping into `while read`: a pipeline
# runs its right-hand side in a subshell, so the counter would be incremented in
# a process that exits before it can be read, and every missing check would be
# forgotten by the time the total is tested.
MISSING=0
OLD_IFS="$IFS"
IFS='
'
for REQUIRED in $REQUIRE_CHECKS_NAMES; do
  [ -z "$REQUIRED" ] && continue
  FOUND="$(jq -r --arg n "$REQUIRED" \
    '[.[] | select(.name == $n and .conclusion == "success")] | length' "$CHECKS_FILE")"
  if [ "$FOUND" -eq 0 ]; then
    echo "ERROR: no successful '$REQUIRED' for $REQUIRE_CHECKS_COMMIT." >&2
    MISSING=$((MISSING + 1))
  else
    echo "OK: $REQUIRED"
  fi
done
IFS="$OLD_IFS"

if [ "$MISSING" -ne 0 ]; then
  echo "ERROR: $MISSING required check(s) did not pass for $REQUIRE_CHECKS_COMMIT." >&2
  echo "Tag a commit that passed on the default branch, or re-run the failed jobs for it." >&2
  exit 1
fi

echo "All required checks passed for $REQUIRE_CHECKS_COMMIT."
