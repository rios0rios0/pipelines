#!/usr/bin/env sh

# Refuse to deploy a release tag to production when the repository already has
# a newer one.
#
# Every deployment workflow here deploys `production` from a TAG run, and a tag
# run starts whenever a tag is pushed -- whoever pushes it, and whatever version
# it names. So a job that pushes a superseded tag rolls production back to it.
# That is not hypothetical: a weekly reconciliation job re-pushed, at their bump
# commits, the tags of bumps that had failed their gate and been superseded
# (backend `2.1.0`/`2.1.1` after `2.1.2`, frontend `0.4.0` after `0.4.1`), and
# every one of those pushes started a production deploy of a release weeks old.
# They all failed for unrelated reasons. One that had succeeded would have
# replaced the release production was running, with every check green.
#
# So a tag run compares the tag it deploys with the highest SemVer tag in the
# repository, and a LOWER one is not deployed unless a rollback is asked for. A
# tag of equal precedence deploys -- a re-run of the newest release is not a
# rollback -- and so does everything this script cannot order: a run on a
# branch, a tag that names no SemVer version, a repository whose tags name
# none. Those behave exactly as they did before this guard existed.
#
# The rule and why each part of it is shaped this way:
#
#   - The newest release is read from the REMOTE (`git ls-remote`), not from the
#     clone: a CI checkout fetches one ref, so its local tags are a sample of
#     the repository's, and a guard reading them would approve the very tag it
#     exists to refuse.
#   - The tag being deployed is counted among the repository's tags, so a tag
#     deleted between its push and this check still compares with itself.
#   - Precedence is SemVer's own (`global/scripts/shared/semver.sh`): a release
#     outranks its pre-releases, which `sort -V` and a plain
#     `git tag --sort=v:refname` both get backwards.
#   - A guard that cannot read the tags reaches NO verdict and exits 1. Waving
#     the deploy through would make the outage this guard is least able to see
#     the one in which it approves a rollback.
#
# Environment:
#
#   RELEASE_GUARD_TAG             The tag being deployed. Unset, the run's own
#                                 tag: `GITHUB_REF_NAME` when `GITHUB_REF_TYPE`
#                                 is `tag`, `CI_COMMIT_TAG` on GitLab, and
#                                 `BUILD_SOURCEBRANCH` minus `refs/tags/` on
#                                 Azure DevOps -- the three `build-version.sh`
#                                 reads. Empty on a branch run, which deploys.
#   RELEASE_GUARD_TAGS            The repository's tags, one per line. Unset,
#                                 they are listed from RELEASE_GUARD_REMOTE.
#   RELEASE_GUARD_REMOTE          The remote whose tags are listed, from the
#                                 working directory's clone (default `origin`).
#   RELEASE_GUARD_RETRY_DELAYS    The seconds to wait before asking the remote
#                                 again after a failed listing (default `2 4`:
#                                 three attempts). Empty asks once.
#   RELEASE_GUARD_ALLOW_ROLLBACK  `true` deploys an older tag on purpose: a
#                                 rollback. Read case-insensitively, as
#                                 `deploy_is_truthy` reads every flag (Azure
#                                 DevOps renders a boolean as `True`); anything
#                                 else, a typo included, refuses -- the safe
#                                 direction for this flag to fail in.
#   RELEASE_GUARD_ROLLBACK_HINT   The sentence telling a reader of a refusal how
#                                 to roll back on purpose, since that depends on
#                                 how the caller wired this guard.
#
# The verdict is `deploy=true` or `deploy=false`, with `newest=<tag>` when the
# tag was compared: printed, written to `$REPORT_PATH/verdict.txt`, and on
# GitHub Actions also to `$GITHUB_OUTPUT` and the job summary. The exit status
# is 0 for either verdict and 1 when none was reached.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="release-guard" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"
. "$SCRIPTS_DIR/global/scripts/shared/semver.sh"

RG_REMOTE="${RELEASE_GUARD_REMOTE:-origin}"
RG_HINT="${RELEASE_GUARD_ROLLBACK_HINT:-To roll back on purpose, run the workflow by hand on this tag with \`allow_rollback\` set to \`true\`.}"
RG_VERDICT_FILE="$REPORT_PATH/verdict.txt"

RG_TAG="${RELEASE_GUARD_TAG:-}"
if [ -z "$RG_TAG" ]; then
  if [ "${GITHUB_REF_TYPE:-}" = 'tag' ]; then
    RG_TAG="${GITHUB_REF_NAME:-}"
  elif [ -n "${CI_COMMIT_TAG:-}" ]; then
    RG_TAG="$CI_COMMIT_TAG"
  else
    case "${BUILD_SOURCEBRANCH:-}" in
      refs/tags/?*) RG_TAG="${BUILD_SOURCEBRANCH#refs/tags/}" ;;
    esac
  fi
fi

# rg_summary <markdown>
#
# Appends one paragraph to the job summary on GitHub Actions; anywhere else the
# printed verdict is the whole record.
rg_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# rg_verdict <deploy> [newest]
#
# Records the verdict everywhere it is read and ends the script with status 0.
# `newest` is always a SemVer tag, which holds only `[0-9A-Za-z.+-]`, so it is
# safe to write into `$GITHUB_OUTPUT`; the tag under judgement is never written
# there, because a name this script could not order may hold anything.
rg_verdict() {
  {
    echo "deploy=$1"
    [ -n "${2:-}" ] && echo "newest=$2"
  } > "$RG_VERDICT_FILE"
  cat "$RG_VERDICT_FILE"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    cat "$RG_VERDICT_FILE" >> "$GITHUB_OUTPUT"
  fi
  exit 0
}

if [ -z "$RG_TAG" ]; then
  echo "Not a tag run: there is no release to compare, so the deploy goes ahead as before."
  rg_verdict 'true'
fi

# A name that is not a version cannot be ordered, and guessing an order for it
# would refuse deploys that have always worked. It deploys exactly as before.
# Backticks (octal 140) are dropped from it before it reaches the Markdown
# summary, where one would close the code span around it.
if ! semver_version "$RG_TAG" > /dev/null; then
  echo "'$RG_TAG' names no SemVer version, so it is not compared: the deploy goes ahead as before."
  RG_SHOWN="$(printf '%s' "$RG_TAG" | tr -d '\140')"
  rg_summary "**Release guard:** \`$RG_SHOWN\` names no SemVer version, so it was not compared with the other tags: the guard lets it deploy, as before."
  rg_verdict 'true'
fi

# rg_list_tags
#
# Lists the remote's tags into RG_LISTING, asking again after each delay in
# RELEASE_GUARD_RETRY_DELAYS (seconds, default `2 4`), so a blip in the
# remote is not a failed deploy. The listing is captured whole before it is
# parsed, so a failed one is told apart from a repository with no tags: the
# exit status read is git's, not a pipe's.
rg_list_tags() {
  for _rg_delay in ${RELEASE_GUARD_RETRY_DELAYS-2 4} ''; do
    if RG_LISTING="$(git ls-remote --tags --refs "$RG_REMOTE")"; then
      return 0
    fi
    [ -n "$_rg_delay" ] || return 1
    echo "Listing the tags of '$RG_REMOTE' failed; asking again in ${_rg_delay}s." >&2
    sleep "$_rg_delay"
  done
  return 1
}

if [ -n "${RELEASE_GUARD_TAGS+set}" ]; then
  RG_TAGS="$RELEASE_GUARD_TAGS"
else
  if ! rg_list_tags; then
    echo "ERROR: could not list the tags of '$RG_REMOTE' from $(pwd)." >&2
    echo "The guard needs a clone of the repository whose remote it can read: on GitHub Actions, a checkout with its credentials persisted and 'contents: read'." >&2
    echo "No verdict was reached, so nothing is deployed. Re-run the job once the remote answers." >&2
    exit 1
  fi
  RG_TAGS="$(printf '%s\n' "$RG_LISTING" | sed -n 's|^[^[:space:]]*[[:space:]][[:space:]]*refs/tags/||p')"
fi

RG_NEWEST="$(printf '%s\n%s\n' "$RG_TAG" "$RG_TAGS" | semver_highest)"
if [ -z "$RG_NEWEST" ] || ! RG_ORDER="$(semver_compare "$RG_TAG" "$RG_NEWEST")"; then
  echo "ERROR: could not order '$RG_TAG' against the repository's tags." >&2
  exit 1
fi

if [ "$RG_ORDER" -ge 0 ]; then
  echo "'$RG_TAG' is the newest release tag in the repository: the deploy goes ahead."
  rg_summary "**Release guard:** \`$RG_TAG\` is the newest release tag in this repository, so the guard lets it deploy."
  rg_verdict 'true' "$RG_NEWEST"
fi

if deploy_is_truthy "${RELEASE_GUARD_ALLOW_ROLLBACK:-false}"; then
  echo "'$RG_TAG' is older than '$RG_NEWEST', the newest release tag, and a rollback was asked for: the deploy goes ahead."
  if [ "${GITHUB_ACTIONS:-}" = 'true' ]; then
    echo "::warning title=Release guard::rolling back on purpose: $RG_TAG is older than $RG_NEWEST, the newest release tag"
  fi
  rg_summary "**Release guard:** rolling back on purpose. \`$RG_TAG\` is older than \`$RG_NEWEST\`, the newest release tag in this repository, and a rollback was asked for, so the guard lets it deploy."
  rg_verdict 'true' "$RG_NEWEST"
fi

echo "'$RG_TAG' is older than '$RG_NEWEST', the newest release tag in the repository: it is NOT deployed, because deploying it would roll production back."
echo "$RG_HINT"
if [ "${GITHUB_ACTIONS:-}" = 'true' ]; then
  echo "::warning title=Release guard::$RG_TAG is older than $RG_NEWEST, the newest release tag, so it was not deployed"
fi
rg_summary "**Release guard:** \`$RG_TAG\` is older than \`$RG_NEWEST\`, the newest release tag in this repository, so it is **not deployed**: deploying it would roll production back. $RG_HINT"
rg_verdict 'false' "$RG_NEWEST"
