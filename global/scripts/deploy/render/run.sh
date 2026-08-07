#!/usr/bin/env sh

# Deploy to Render.
#
# Render is the closest thing left to what Heroku's free tier used to be: a
# permanent free instance type that runs an actual server process (512 MB RAM,
# 0.1 CPU) rather than only static files or edge functions. Two properties of
# that tier decide whether it fits an MVP, and both are easy to discover too
# late:
#
#   - A free web service SPINS DOWN after 15 minutes without traffic, and the
#     next request pays a 30-60s cold start. Fine for a demo; fatal for a
#     webhook receiver or anything with a health check.
#   - A free PostgreSQL database EXPIRES 30 days after creation, with a 14-day
#     grace period before the data is deleted. It is a trial, not a free tier.
#
# There are two ways to trigger a deploy, and they are not equivalent:
#
#   - RENDER_DEPLOY_HOOK_URL is a single unauthenticated POST. It is
#     fire-and-forget: Render returns 200 for "I accepted the request", so the
#     pipeline goes GREEN even when the build that follows fails. Convenient,
#     but it makes the deploy job's status meaningless as a signal.
#   - RENDER_API_KEY + RENDER_SERVICE_ID uses the REST API, which returns a
#     deploy id that this script then POLLS to a terminal state. The job's
#     status reflects the deploy's actual outcome.
#
# The API path is therefore preferred whenever both variables are present, and
# the hook path warns about what it cannot tell you.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deploy-render" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"

DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-production}"
export DEPLOY_ENVIRONMENT

RENDER_API_URL="${RENDER_API_URL:-https://api.render.com/v1}"
RENDER_POLL_INTERVAL="${RENDER_POLL_INTERVAL:-10}"
RENDER_POLL_TIMEOUT="${RENDER_POLL_TIMEOUT:-1800}"

# Named once so the receipt written on every exit path cannot drift between them.
PROVIDER="render"

if [ -z "${RENDER_API_KEY:-}" ] && [ -z "${RENDER_DEPLOY_HOOK_URL:-}" ]; then
  echo "ERROR: neither RENDER_API_KEY nor RENDER_DEPLOY_HOOK_URL is set." >&2
  echo "Create an API key at https://dashboard.render.com/u/settings#api-keys (preferred," >&2
  echo "because the deploy outcome is then reflected in this job's status), or copy the" >&2
  echo "service's deploy hook from Settings > Deploy Hook." >&2
  exit 1
fi

# ---------------------------------------------------------------- hook path --
if [ -z "${RENDER_API_KEY:-}" ]; then
  echo "WARN: deploying via RENDER_DEPLOY_HOOK_URL. Render acknowledges the request without" >&2
  echo "WARN: reporting whether the build succeeds, so this job cannot fail on a broken" >&2
  echo "WARN: deploy. Set RENDER_API_KEY and RENDER_SERVICE_ID to poll for the real result." >&2

  # The hook URL embeds its own secret key, so it is passed on stdin via
  # `curl --config -` rather than on argv, where `ps` and `command.txt` would
  # both capture it. Only the redacted form is recorded.
  # `proto = "=https"` pins the transport. The hook URL is consumer-supplied and
  # carries its secret in the query string, so an `http://` value -- pasted by
  # mistake or injected into a pipeline variable -- would put that secret on the
  # wire in cleartext. Rejecting the request is the right outcome; downgrading
  # silently is not.
  if deploy_note_command "curl --config - # POST (RENDER_DEPLOY_HOOK_URL redacted)"; then
    if ! printf 'url = "%s"\nrequest = "POST"\nproto = "=https"\nproto-redir = "=https"\nfail\nsilent\nshow-error\n' "$RENDER_DEPLOY_HOOK_URL" \
      | curl --config -; then
      echo "ERROR: the Render deploy hook returned a non-success status." >&2
      exit 1
    fi
    echo "Deploy hook accepted."
  fi

  deploy_record "$PROVIDER" "deploy-hook"
  exit 0
fi

# ----------------------------------------------------------------- API path --
deploy_require_env "RENDER_SERVICE_ID" \
  "The service id (starts with 'srv-'), from the service's dashboard URL."

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required to parse the Render API response but is not installed." >&2
  exit 1
fi

# `curl --config -` keeps the bearer token off argv and out of `ps`; the token
# is written to curl's stdin, which is not readable from the process table.
# `proto = "=https"` pins the transport for the same reason as the hook path
# above: RENDER_API_URL is overridable, and a plain-HTTP override would send the
# bearer token in cleartext.
render_api() {
  _ra_method="$1"
  _ra_path="$2"

  printf 'url = "%s%s"\nrequest = "%s"\nheader = "Authorization: Bearer %s"\nheader = "Accept: application/json"\nheader = "Content-Type: application/json"\ndata = "{}"\nproto = "=https"\nproto-redir = "=https"\nfail\nsilent\nshow-error\n' \
    "$RENDER_API_URL" "$_ra_path" "$_ra_method" "$RENDER_API_KEY" \
    | curl --config -

  return $?
}

if ! deploy_note_command "curl --config - # POST $RENDER_API_URL/services/$RENDER_SERVICE_ID/deploys"; then
  deploy_record "$PROVIDER" "$RENDER_SERVICE_ID"
  exit 0
fi

echo "Triggering deploy for $RENDER_SERVICE_ID..."
CREATE_RESPONSE=$(render_api "POST" "/services/$RENDER_SERVICE_ID/deploys")
if [ -z "$CREATE_RESPONSE" ]; then
  echo "ERROR: the Render API returned an empty response when creating the deploy." >&2
  exit 1
fi

DEPLOY_ID=$(printf '%s' "$CREATE_RESPONSE" | jq -r '.id // empty')
if [ -z "$DEPLOY_ID" ]; then
  echo "ERROR: could not read a deploy id from the Render API response:" >&2
  printf '%s\n' "$CREATE_RESPONSE" >&2
  exit 1
fi
echo "Deploy $DEPLOY_ID created; polling until it reaches a terminal state."

# Poll to a terminal state. The elapsed counter is derived from the number of
# polls rather than wall-clock arithmetic so the loop stays POSIX and needs no
# `date` maths; `RENDER_POLL_TIMEOUT` bounds a hung build instead of letting it
# run to the CI platform's own (much longer) job timeout.
ELAPSED=0
while [ "$ELAPSED" -lt "$RENDER_POLL_TIMEOUT" ]; do
  sleep "$RENDER_POLL_INTERVAL"
  ELAPSED=$((ELAPSED + RENDER_POLL_INTERVAL))

  STATUS=$(render_api "GET" "/deploys/$DEPLOY_ID" | jq -r '.status // empty')
  if [ -z "$STATUS" ]; then
    echo "WARN: could not read a status from the Render API; retrying." >&2
    continue
  fi
  echo "  [${ELAPSED}s] status: $STATUS"

  case "$STATUS" in
    live)
      echo "Deploy $DEPLOY_ID is live."
      deploy_record "$PROVIDER" "$RENDER_SERVICE_ID"
      exit 0
      ;;
    build_failed | update_failed | pre_deploy_failed | canceled | deactivated)
      echo "ERROR: deploy $DEPLOY_ID finished in state '$STATUS'." >&2
      echo "See https://dashboard.render.com/web/$RENDER_SERVICE_ID/deploys/$DEPLOY_ID for the log." >&2
      deploy_record "$PROVIDER" "$RENDER_SERVICE_ID"
      exit 1
      ;;
    *)
      # created / build_in_progress / update_in_progress / pre_deploy_in_progress
      ;;
  esac
done

echo "ERROR: deploy $DEPLOY_ID did not reach a terminal state within ${RENDER_POLL_TIMEOUT}s." >&2
echo "The deploy may still be running -- check the Render dashboard before retrying." >&2
deploy_record "$PROVIDER" "$RENDER_SERVICE_ID"
exit 1
