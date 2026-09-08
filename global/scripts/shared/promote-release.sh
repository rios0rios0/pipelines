#!/usr/bin/env sh
#
# promote-release.sh — start the tag run for a release the pipeline has just cut.
#
# `delivery > release` creates the version tag with the job's own `GITHUB_TOKEN`, and GitHub
# starts no workflow run from an event that token caused. So the `refs/tags/X.Y.Z` run -- the
# one every deploy job resolves `production` on (`github.ref_type == 'tag'`) -- never started on
# its own: a merged bump stopped at `staging`, and a human pushed the tag again by hand to get
# it any further. `workflow_dispatch` is the one event GitHub exempts from that rule, so this
# dispatches the CALLING workflow on the new tag. The run that starts has
# `github.ref == refs/tags/X.Y.Z` and `github.ref_type == 'tag'`; it differs from a pushed tag's
# run only in `github.event_name`, which every gate in this library already accepts.
#
# Read from the environment. The release action sets the first two; the runner sets the rest:
#
#   PROMOTE_TAG           the tag just created, e.g. `1.2.3` or `v1.2.3`          (required)
#   GH_TOKEN              a token holding `actions: write` on the repository      (required)
#   GITHUB_REF            a tag ref is refused politely: that run IS the promotion, and
#                         dispatching it again would loop
#   GITHUB_WORKFLOW_REF   `owner/repo/.github/workflows/<file>@refs/heads/main` -- the file to
#                         dispatch is the caller's, and inside a reusable workflow this is the
#                         only variable that names it
#   GITHUB_REPOSITORY     `owner/repo`
#   GITHUB_API_URL        defaults to https://api.github.com
#   PROMOTE_ATTEMPTS      tries on a 5xx or a transport failure (default 3)
#   PROMOTE_RETRY_DELAY   seconds between those tries (default 5)
#   PROMOTE_DRY_RUN       `true` prints the request it would send and sends nothing
#
# The token reaches curl through a config file on stdin, never argv: on a self-hosted runner
# argv is readable in `ps` by every process on the host, and the same rule holds for every
# credential the deploy scripts pass. Exit 0 once the dispatch is accepted (HTTP 204) or when
# there is nothing to do; every refusal is spelled out with what fixes it, because the four
# ways this call fails all look alike from the run summary.
set -eu

PROMOTE_TAG="${PROMOTE_TAG:?PROMOTE_TAG is required: the tag to promote}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
GITHUB_REF="${GITHUB_REF:-}"
GITHUB_WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
PROMOTE_ATTEMPTS="${PROMOTE_ATTEMPTS:-3}"
PROMOTE_RETRY_DELAY="${PROMOTE_RETRY_DELAY:-5}"
PROMOTE_DRY_RUN="${PROMOTE_DRY_RUN:-false}"

case "$GITHUB_REF" in
  refs/tags/*)
    echo "$GITHUB_REF is a tag ref: this run is the promotion, nothing to dispatch."
    exit 0
    ;;
esac

if [ -z "$GITHUB_WORKFLOW_REF" ] || [ -z "$GITHUB_REPOSITORY" ]; then
  echo "::error::GITHUB_WORKFLOW_REF and GITHUB_REPOSITORY are required to know which workflow to dispatch, and the runner sets both -- run this from a workflow step." >&2
  exit 1
fi

# `owner/repo/.github/workflows/default.yaml@refs/heads/main` -> `default.yaml`. The dispatch
# endpoint takes a file name, and GitHub reads that file at the ref being dispatched -- so the
# `workflow_dispatch:` trigger has to exist in the file AT THE TAG, which it does whenever the
# bump commit carries it.
workflow_path="${GITHUB_WORKFLOW_REF%%@*}"
workflow_file="${workflow_path##*/}"
if [ -z "$workflow_file" ]; then
  echo "::error::could not read a workflow file name from GITHUB_WORKFLOW_REF='${GITHUB_WORKFLOW_REF}'." >&2
  exit 1
fi

url="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/workflows/${workflow_file}/dispatches"
payload="{\"ref\":\"${PROMOTE_TAG}\"}"

if [ "$PROMOTE_DRY_RUN" = "true" ]; then
  echo "DRY RUN: POST ${url} ${payload}"
  exit 0
fi

if [ -z "$GH_TOKEN" ]; then
  echo "::error::GH_TOKEN is required: a token holding 'actions: write' on ${GITHUB_REPOSITORY}." >&2
  exit 1
fi

body="$(mktemp)"
errors="$(mktemp)"
trap 'rm -f "$body" "$errors"' EXIT

attempt=1
while :; do
  status="$(printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" | curl --silent --show-error \
    --config - \
    --output "$body" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --data "$payload" \
    "$url" 2>> "$errors")" || status='000'

  case "$status" in
    204)
      echo "dispatched ${workflow_file} on ${PROMOTE_TAG}: the tag run is queued in ${GITHUB_REPOSITORY}."
      exit 0
      ;;
    401)
      echo "::error::GitHub refused the token (HTTP 401) while dispatching ${workflow_file} on ${PROMOTE_TAG}." >&2
      break
      ;;
    403)
      echo "::error::the token may not dispatch workflows in ${GITHUB_REPOSITORY} (HTTP 403). The job that calls the release action must be granted 'actions: write' -- add it beside the 'contents: write' the release itself already needs, in the calling workflow's 'permissions:' block." >&2
      break
      ;;
    404)
      echo "::error::${workflow_file} was not found in ${GITHUB_REPOSITORY} at ${PROMOTE_TAG} (HTTP 404), or the token cannot see it. The file dispatched is the calling workflow's own, read from GITHUB_WORKFLOW_REF='${GITHUB_WORKFLOW_REF}'." >&2
      break
      ;;
    422)
      echo "::error::GitHub would not dispatch ${workflow_file} on ${PROMOTE_TAG} (HTTP 422): the file has no 'on: workflow_dispatch:' trigger at that tag, or the tag does not exist. Declare 'workflow_dispatch:' in the calling workflow -- the run that promotes a release is a dispatch of it." >&2
      break
      ;;
    5*|000)
      if [ "$attempt" -ge "$PROMOTE_ATTEMPTS" ]; then
        echo "::error::dispatching ${workflow_file} on ${PROMOTE_TAG} failed ${attempt} times (last HTTP ${status})." >&2
        break
      fi
      echo "HTTP ${status} dispatching ${workflow_file} on ${PROMOTE_TAG} (attempt ${attempt} of ${PROMOTE_ATTEMPTS}); retrying in ${PROMOTE_RETRY_DELAY}s." >&2
      sleep "$PROMOTE_RETRY_DELAY"
      attempt=$((attempt + 1))
      continue
      ;;
    *)
      echo "::error::unexpected HTTP ${status} dispatching ${workflow_file} on ${PROMOTE_TAG}." >&2
      break
      ;;
  esac
done

echo "response: $(head -c 400 "$body" | tr '\n' ' ') $(head -c 200 "$errors" | tr '\n' ' ')" >&2
echo "The release exists; only its promotion did not start. Start it by hand with: gh workflow run ${workflow_file} --repo ${GITHUB_REPOSITORY} --ref ${PROMOTE_TAG}" >&2
exit 1
