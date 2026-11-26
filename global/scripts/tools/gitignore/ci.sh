#!/usr/bin/env sh
# The `quality:gitignore` check every pipeline runs beside `quality:basic-checks`: is the project's
# generated `.gitignore` block (`make gitignore`) in step with the shared ignore rules?
#
# It REPORTS by default rather than failing. A block goes stale through no change of the pull
# request it is checked on: a fragment changes here, or the generator starts reading a language the
# project's CI already imports. Failing on that would turn every consumer's pull requests red at
# once, for a change none of them made, and the weekly config-and-docs refresh of
# rios0rios0/config-automation already regenerates the block in every repository it reaches.
# GITIGNORE_CHECK sets how the result is held:
#
#   warn     (default) a stale or missing block is reported, and passes
#   enforce  a stale or missing block fails: for a project that wants the gate, such as one the
#            refresh does not reach
#   off      nothing is checked
#
# Exit status: 0, or 1 when the block is stale or missing under `enforce`.
set -u

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(dirname "$(realpath "$0")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi

mode="${GITIGNORE_CHECK:-warn}"
case "$mode" in
  warn | enforce | off) ;;
  *)
    echo "WARNING: GITIGNORE_CHECK='$mode' is none of warn, enforce, off; using warn." >&2
    mode='warn'
    ;;
esac

if [ "$mode" = 'off' ]; then
  echo "GITIGNORE_CHECK=off: the shared .gitignore block is not checked."
  exit 0
fi

if sh "$SCRIPTS_DIR/global/scripts/tools/gitignore/run.sh" --check .; then
  exit 0
fi

if [ "$mode" = 'enforce' ]; then
  echo "The shared .gitignore block is stale or missing (GITIGNORE_CHECK=enforce). Run 'make gitignore' and commit the result." >&2
  exit 1
fi

# Reported, not failed. Each platform's own annotation, so the warning shows on the run's summary
# rather than only in the log; none of them changes the job's result.
message="the shared .gitignore block is stale or missing: run 'make gitignore' and commit the result (GITIGNORE_CHECK=warn reports it without failing; set enforce to fail on it)"
if [ -n "${TF_BUILD:-}" ]; then
  echo "##vso[task.logissue type=warning]$message"
elif [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::warning title=.gitignore block::$message"
else
  echo "WARNING: $message"
fi
exit 0
