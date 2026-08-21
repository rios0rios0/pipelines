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

# A dry run resolves what would be asserted without calling the API, matching
# every other script in this family and keeping the validation harness offline.
if deploy_is_dry_run; then
  echo "DRY RUN: would require these checks on $REQUIRE_CHECKS_COMMIT:"
  printf '%s\n' "$REQUIRE_CHECKS_NAMES" | while IFS= read -r _rc_name; do
    [ -n "$_rc_name" ] && echo "  - $_rc_name"
  done
  exit 0
fi

# Below the dry-run exit on purpose. A dry run reaches its verdict without
# calling the API or reading any JSON, so demanding these binaries first would
# make the hermetic path depend on tools it never uses -- and fail on a runner
# that has neither. `deploy_npm_cli` skips its own installation on a dry run for
# the same reason.
if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: 'jq' is required to read check runs but is not installed." >&2
  exit 1
fi

# `gh` is PREFERRED, not required. It ships on GitHub-hosted runners and on
# almost no self-hosted one, and this was the only script in the deploy family
# that needed it -- `render/run.sh` already reaches the same kind of API with
# `curl` and `jq`, so the fallback below adds no assumption the family did not
# already make. A consumer on a self-hosted runner otherwise fails at the FIRST
# step of its deployment, with a message about a CLI it has no reason to have
# installed, after the whole pipeline has already passed.
if command -v gh > /dev/null 2>&1; then
  RC_TRANSPORT='gh'
elif command -v curl > /dev/null 2>&1; then
  RC_TRANSPORT='curl'
else
  echo "ERROR: reading check runs needs either 'gh' or 'curl', and neither is installed." >&2
  exit 1
fi

# `cleanup.sh` re-exports REPORT_PATH as the tool's own subdirectory, so the
# tool name must NOT be repeated here.
CHECKS_FILE="$REPORT_PATH/check-runs.json"

# Both transports emit the same thing: one `{name, conclusion}` object per line,
# which `jq -s` then collects into the array everything below reads. Keeping the
# shapes identical is what lets the matching logic -- the part that has actually
# been wrong before -- stay transport-agnostic and be tested once.
rc_fetch_with_gh() {
  gh api --paginate \
    "repos/$REQUIRE_CHECKS_REPOSITORY/commits/$REQUIRE_CHECKS_COMMIT/check-runs" \
    --jq '.check_runs[] | {name, conclusion}'
}

# Paginated by hand because the REST endpoint has no cursor worth following
# here: a page shorter than the limit is the last one. Capped so a malformed
# response cannot spin forever.
rc_fetch_with_curl() {
  _rc_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$_rc_token" ]; then
    echo "ERROR: no token available. Set GH_TOKEN (the composite action passes it)." >&2
    return 1
  fi
  _rc_api="${GITHUB_API_URL:-https://api.github.com}"
  _rc_page=1
  while [ "$_rc_page" -le 20 ]; do
    # `--location`, because a repository or an organisation that has been RENAMED
    # answers **301**, not 404, and the body of that redirect is a `message`
    # object rather than a page of check runs. `-f` does not catch it -- it fails
    # on 4xx and 5xx only -- so without this the redirect body was parsed as the
    # answer, `.check_runs` read as null, `length` answered 0, and the gate
    # reported every required check as missing. That is the exact opposite of
    # what happened: a fully green commit refused by a deploy whose log blames
    # the tests. `github.repository` is resolved when the run is CREATED, so a
    # rename between that moment and the deployment job reaching this script is
    # enough, and the deploy is the last job in the run.
    #
    # `--proto '=https' --proto-redir '=https'`, because following a redirect is
    # only safe if it cannot be followed into plain HTTP with the bearer token
    # attached. curl already drops the Authorization header when a redirect
    # crosses to another HOST; the scheme is the half it would otherwise keep.
    _rc_body="$(curl -sS -f -L --proto '=https' --proto-redir '=https' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $_rc_token" \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$_rc_api/repos/$REQUIRE_CHECKS_REPOSITORY/commits/$REQUIRE_CHECKS_COMMIT/check-runs?per_page=100&page=$_rc_page")" \
      || return 1

    # An answer that is not a check-run page is a MISCONFIGURATION, and it must
    # never be readable as "this commit has no checks": those are opposite
    # verdicts, only one of them is the repository's fault, and the second is the
    # one somebody would spend an afternoon re-running green jobs over. Anything
    # without a `check_runs` ARRAY is refused here rather than folded into an
    # empty list -- a redirect body, an error envelope, an HTML error page from a
    # proxy, or a truncated response all land in this branch.
    if [ "$(printf '%s' "$_rc_body" \
      | jq -r 'if type == "object" and (.check_runs | type) == "array"
               then "page" else "other" end' 2> /dev/null)" != 'page' ]; then
      echo "ERROR: $_rc_api did not answer a check-run page for $REQUIRE_CHECKS_REPOSITORY@$REQUIRE_CHECKS_COMMIT." >&2
      echo "It said: $(printf '%s' "$_rc_body" \
        | jq -r '.message? // "the payload carried no check_runs array"' 2> /dev/null)" >&2
      echo "Check that REQUIRE_CHECKS_REPOSITORY still names this repository -- a renamed owner or repo answers a redirect here." >&2
      return 1
    fi

    printf '%s' "$_rc_body" | jq -c '.check_runs[] | {name, conclusion}'
    _rc_count="$(printf '%s' "$_rc_body" | jq -r '.check_runs | length')"
    [ "$_rc_count" -lt 100 ] && break
    _rc_page=$((_rc_page + 1))
  done
  unset _rc_token _rc_api _rc_page _rc_body _rc_count
}

# Collected to a file and THEN folded into an array, rather than piped straight
# into `jq -s`. A pipeline reports the status of its RIGHT-hand side, and `jq -s`
# succeeds on empty input by answering `[]` -- so every refusal the fetch
# function raises was discarded, the gate carried on with an empty list, and a
# missing token or an unreadable repository surfaced as "no successful check",
# i.e. as a commit that had failed rather than as a job that was misconfigured.
# `pipefail` is not POSIX, so the pipeline is what has to go.
RAW_FILE="$REPORT_PATH/check-runs.jsonl"
echo "Reading check runs through '$RC_TRANSPORT'."
if ! "rc_fetch_with_$RC_TRANSPORT" > "$RAW_FILE"; then
  echo "ERROR: failed to read check runs for $REQUIRE_CHECKS_COMMIT." >&2
  echo "The job needs 'checks: read' permission and a token that can see this repository." >&2
  exit 1
fi
jq -s '.' < "$RAW_FILE" > "$CHECKS_FILE"
rm -f "$RAW_FILE"

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
  # Exact match first, then a SUFFIX match on the ` / `-delimited path.
  #
  # GitHub composes a check's name from the calling job and the called workflow's
  # job, so a stage this repository publishes as `tests > test:all` is recorded as
  # `default / go / tests > test:all` once a consumer calls it through a reusable
  # workflow -- and the prefix changes again if either job is renamed. Matching
  # only on equality made this list silently unsatisfiable: every name read as
  # missing, and the fix was to paste a prefix that is not the caller's to
  # guarantee. That is exactly the coupling a shared gate should not have.
  #
  # The suffix is anchored on ` / ` so it can only match a whole trailing segment:
  # `tests > test:all` matches `default / go / tests > test:all` and never
  # `smoke-tests > test:all`. A caller that wants the strict form can still write
  # the fully-qualified name, which the equality branch takes first.
  FOUND="$(jq -r --arg n "$REQUIRED" \
    '[.[] | select(.conclusion == "success")
          | select(.name == $n or (.name | endswith(" / " + $n)))] | length' "$CHECKS_FILE")"
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
