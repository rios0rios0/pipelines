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
# A BRANCH run that hands over its `needs` context is decided from those jobs
# instead, without reading check runs at all -- see REQUIRE_CHECKS_NEEDS below.
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

# ON A BRANCH RUN, THE JOBS THIS DEPLOYMENT NEEDS ARE THE VERDICT, NOT THE CHECK
# RUNS. There the required checks are jobs of this same run, and the deployment
# job cannot start until every job it `needs:` has finished, so `toJSON(needs)`
# -- passed in as REQUIRE_CHECKS_NEEDS -- carries their results from the same
# scheduler that started this job. A check run is a second record of each of
# those jobs, written separately, and it can lag behind them or never arrive:
# during a GitHub Actions incident (githubstatus.com, 2026-10-22, "Incident with
# Actions Results") a CodeQL job finished, the job waiting on it started seven
# seconds later, and its check run still read `in_progress` almost an hour on.
# Read through the check runs that was a pending required check, and this gate
# refused a deploy whose every check had passed.
#
# Every result must be `success`. A reusable workflow reports `success` when some
# of its jobs were skipped and the rest passed, and `cancelled` when one of them
# was cancelled (both read off public runs that print `toJSON(needs)`), so
# `success` is the one value saying nothing failed and nothing was cut short.
#
# Only on a branch, and only for this run's own commit and repository. On a tag
# the checks are SKIPPED while the delivery job still runs, so the workflow
# holding them reports `success` all the same -- the hole this gate exists for --
# and a tag reads the check runs the default-branch push left. A commit or a
# repository other than this run's is not covered by this run's jobs at all. Any
# ref type but `branch`, an unknown one included, reads check runs, and so does a
# caller that passes no `needs`, which keeps a hand-written deploy job as it was.
REQUIRE_CHECKS_NEEDS="${REQUIRE_CHECKS_NEEDS:-}"
REQUIRE_CHECKS_REF_TYPE="${REQUIRE_CHECKS_REF_TYPE:-${GITHUB_REF_TYPE:-}}"
RC_FROM_NEEDS='false'
if [ -n "$REQUIRE_CHECKS_NEEDS" ]; then
  if [ "$REQUIRE_CHECKS_REF_TYPE" != 'branch' ]; then
    echo "A '${REQUIRE_CHECKS_REF_TYPE:-unknown}' run, not a branch run: the jobs it needs prove nothing here, so check runs decide."
  elif [ "$REQUIRE_CHECKS_COMMIT" != "${GITHUB_SHA:-}" ]; then
    echo "Verifying $REQUIRE_CHECKS_COMMIT, not this run's own commit: the jobs it needs do not cover it, so check runs decide."
  elif [ "$REQUIRE_CHECKS_REPOSITORY" != "${GITHUB_REPOSITORY:-}" ]; then
    echo "Verifying $REQUIRE_CHECKS_REPOSITORY, not this run's repository: the jobs it needs do not cover it, so check runs decide."
  else
    RC_FROM_NEEDS='true'
  fi
fi

# A dry run resolves what would be asserted without calling the API, matching
# every other script in this family and keeping the validation harness offline.
if deploy_is_dry_run; then
  if [ "$RC_FROM_NEEDS" = 'true' ]; then
    echo "DRY RUN: would require every job this deployment needs to have finished 'success' on $REQUIRE_CHECKS_COMMIT, reading no check runs."
    exit 0
  fi
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
  echo "ERROR: 'jq' is required to read check runs and job results but is not installed." >&2
  exit 1
fi

# Decided before a transport is even chosen, so a branch deploy needs neither
# `gh` nor `curl` and does not depend on the API it no longer reads.
if [ "$RC_FROM_NEEDS" = 'true' ]; then
  # Projected to `{job, result}` before it is written, because the report
  # directory is published as an artifact and a job's outputs do not belong in
  # it. Anything that is not a non-empty object fails here: an empty `needs`
  # would make "every dependency succeeded" vacuously true.
  NEEDS_FILE="$REPORT_PATH/needs.json"
  if ! printf '%s' "$REQUIRE_CHECKS_NEEDS" | jq \
    'if type == "object" and length > 0
     then [to_entries[] | {job: .key, result: (.value.result // "none")}]
     else error("not a needs context") end' > "$NEEDS_FILE" 2> /dev/null; then
    rm -f "$NEEDS_FILE"
    echo "ERROR: REQUIRE_CHECKS_NEEDS is not the needs context of a job that has dependencies." >&2
    echo "Pass toJSON(needs) from a job that declares needs:, or pass nothing to read check runs instead." >&2
    exit 1
  fi

  echo "Branch run on its own commit: deciding from the jobs this deployment needs, not from check runs."
  # Job ids hold no spaces, so a space separates the two fields. Counted with
  # `for` rather than `while read` for the reason given at the check-run loop
  # below: a pipeline would count in a subshell and forget the total. `set -f`
  # keeps an entry from being expanded as a filename pattern on its way in.
  RC_SEEN=0
  RC_BAD=0
  OLD_IFS="$IFS"
  IFS='
'
  set -f
  for _rc_entry in $(jq -r '.[] | "\(.job) \(.result)"' "$NEEDS_FILE"); do
    RC_SEEN=$((RC_SEEN + 1))
    _rc_job="${_rc_entry%% *}"
    _rc_result="${_rc_entry#* }"
    if [ "$_rc_result" = 'success' ]; then
      echo "OK: '$_rc_job' finished 'success'"
    else
      echo "ERROR: '$_rc_job' finished '$_rc_result', not 'success'." >&2
      RC_BAD=$((RC_BAD + 1))
    fi
  done
  set +f
  IFS="$OLD_IFS"

  # `RC_SEEN` is a belt: the fold above already refused an empty object, and a
  # gate whose failure mode would be approval does not get to rely on that.
  if [ "$RC_SEEN" -eq 0 ] || [ "$RC_BAD" -ne 0 ]; then
    echo "ERROR: this run has not shown that the checks passed for $REQUIRE_CHECKS_COMMIT." >&2
    echo "Re-run the jobs that did not finish 'success'." >&2
    exit 1
  fi

  echo "Every job this deployment needs finished 'success' for $REQUIRE_CHECKS_COMMIT, and on a branch the required checks run inside them."
  exit 0
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
      # What the answer SAID, by whatever route can still say it. `jq` produces
      # nothing at all when the body is not JSON -- an HTML error page from a
      # proxy or a gateway, which is the case this guard most needs to be legible
      # for -- and its stderr is suppressed here, so reading `.message` alone
      # leaves the line as `It said:` with nothing after it. The raw first line is
      # the fallback: long enough to recognise `502 Bad Gateway`, truncated so a
      # whole error page cannot be pasted into a job log.
      _rc_said="$(printf '%s' "$_rc_body" | jq -r '.message? // empty' 2> /dev/null)"
      if [ -z "$_rc_said" ]; then
        _rc_said="$(printf '%s' "$_rc_body" | tr '\n\r\t' '   ' | sed -n '1s/\(.\{0,200\}\).*/\1/p')"
      fi
      [ -z "$_rc_said" ] && _rc_said='the response was empty'

      echo "ERROR: $_rc_api did not answer a check-run page for $REQUIRE_CHECKS_REPOSITORY@$REQUIRE_CHECKS_COMMIT." >&2
      echo "It said: $_rc_said" >&2
      echo "Check that REQUIRE_CHECKS_REPOSITORY still names this repository -- a renamed owner or repo answers a redirect here." >&2
      return 1
    fi

    printf '%s' "$_rc_body" | jq -c '.check_runs[] | {name, conclusion}'
    _rc_count="$(printf '%s' "$_rc_body" | jq -r '.check_runs | length')"
    [ "$_rc_count" -lt 100 ] && break
    _rc_page=$((_rc_page + 1))
  done
  unset _rc_token _rc_api _rc_page _rc_body _rc_count _rc_said
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
# CHECKED, and this is the one place in the script where an unchecked command
# would be worst. `jq -s` truncates its target before it fails, so a stream it
# cannot assemble leaves `$CHECKS_FILE` EMPTY -- and an empty file does not make
# the gate refuse, it makes the gate PASS: `jq ... | length` prints nothing, the
# per-name test becomes `[ "" -eq 0 ]`, POSIX `sh` answers "Illegal number" with
# status 2, and `if` reads that as false and takes the `else` branch, which is
# the one that prints `OK`. Every required check reported as passing, on a commit
# whose check runs were never read. A deploy gate is allowed to be wrong in one
# direction only.
if ! jq -s '.' < "$RAW_FILE" > "$CHECKS_FILE"; then
  echo "ERROR: the check runs read from $REQUIRE_CHECKS_REPOSITORY could not be assembled into an array." >&2
  echo "The transport answered, but not in the one-object-per-line shape both transports emit." >&2
  rm -f "$RAW_FILE"
  exit 1
fi
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
  # Fails CLOSED on anything that is not a count. `jq` prints nothing when it
  # cannot read the file, and the arithmetic test errors rather than being false
  # -- which `if` cannot distinguish from a passing check. Belt to the braces
  # above: the fold is now checked, so this should be unreachable, and a gate
  # whose failure mode is "approve everything" does not get to rely on should.
  case "$FOUND" in
    '' | *[!0-9]*) FOUND=0 ;;
  esac
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
