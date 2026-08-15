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
# Either names the service. The id is exact; the name is resolved through the API
# below, which is what lets a caller derive it (`api-staging` / `api-production`)
# instead of storing one more secret per environment.
if [ -z "${RENDER_SERVICE_ID:-}" ] && [ -z "${RENDER_SERVICE_NAME:-}" ]; then
  echo "ERROR: set RENDER_SERVICE_ID or RENDER_SERVICE_NAME." >&2
  echo "  RENDER_SERVICE_ID   the id from the service's dashboard URL (starts with 'srv-')." >&2
  echo "  RENDER_SERVICE_NAME the service name, resolved to an id before deploying." >&2
  exit 1
fi

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

  # The body and its Content-Type belong only on the POST that creates a
  # deploy. Sending `data = "{}"` on the GET poll made curl carry a request
  # body on a read, which some servers and proxies reject outright -- that
  # would have failed the polling loop for a reason unrelated to the deploy it
  # is meant to be reporting on, and the resulting error would have pointed at
  # Render rather than at this script.
  #
  # Emitted as three printf calls rather than one interpolated format string:
  # putting the conditional fragment inside the format would make the body a
  # variable in printf's first argument, which is how format-string injection
  # gets in.
  {
    printf 'url = "%s%s"\nrequest = "%s"\nheader = "Authorization: Bearer %s"\nheader = "Accept: application/json"\n' \
      "$RENDER_API_URL" "$_ra_path" "$_ra_method" "$RENDER_API_KEY"
    if [ "$_ra_method" = "POST" ]; then
      printf 'header = "Content-Type: application/json"\ndata = "{}"\n'
    fi
    printf 'proto = "=https"\nproto-redir = "=https"\nfail\nsilent\nshow-error\n'
  } | curl --config -

  return $?
}

# Resolve a name to an id, when the caller gave a name instead of an id.
#
# `GET /v1/services?name=<name>` is a FILTER, not an exact lookup: Render matches
# on substring, so asking for `api` also answers `api-staging` and
# `api-production`. Every candidate is therefore compared to the requested name
# exactly, here, rather than trusting the first element -- deploying whichever
# service happened to sort first is the kind of mistake that looks like a
# successful deploy.
#
# `type=web_service` narrows it further: a name may be reused across service
# types in one workspace, and this action deploys a web service.
if [ -z "${RENDER_SERVICE_ID:-}" ]; then
  # A dry run must not call the API. Resolution is a read, but it still needs a
  # live key and a reachable Render, which is exactly what a dry run promises not
  # to require -- and the validation suite runs every provider this way.
  if deploy_is_dry_run; then
    echo "DRY RUN (no lookup performed): GET $RENDER_API_URL/services?name=$RENDER_SERVICE_NAME"
    deploy_record "$PROVIDER" "$RENDER_SERVICE_NAME"
    exit 0
  fi

  echo "Resolving Render service '$RENDER_SERVICE_NAME'..."
  # `--data-urlencode` on a GET would turn it into a POST body, so the name is
  # percent-encoded here instead. Only the characters a Render service name can
  # legally contain need escaping, and `jq -rR @uri` does it without adding a
  # dependency this script does not already have.
  ENCODED_NAME=$(printf '%s' "$RENDER_SERVICE_NAME" | jq -rR @uri)

  # Paginated, because the list endpoint caps a page and a workspace can hold
  # more services than one page carries. Without this an exact match on page two
  # is reported as "no service named ...", which sends the reader looking for a
  # service that exists. The cursor is the last item's, per Render's own scheme.
  RENDER_PAGE_SIZE=${RENDER_PAGE_SIZE:-100}
  MATCHES=""
  CURSOR=""
  # Bounded so a server that keeps answering a full page can never spin forever:
  # 100 pages of 100 is 10,000 services, past any real workspace.
  PAGE=0
  while [ "$PAGE" -lt 100 ]; do
    PAGE=$((PAGE + 1))
    LOOKUP_PATH="/services?name=$ENCODED_NAME&type=web_service&limit=$RENDER_PAGE_SIZE"
    if [ -n "$CURSOR" ]; then
      LOOKUP_PATH="$LOOKUP_PATH&cursor=$CURSOR"
    fi

    LOOKUP_RESPONSE=$(render_api "GET" "$LOOKUP_PATH")
    if [ -z "$LOOKUP_RESPONSE" ]; then
      echo "ERROR: the Render API returned nothing when looking up '$RENDER_SERVICE_NAME'." >&2
      echo "Check that RENDER_API_KEY belongs to the workspace that owns the service." >&2
      exit 1
    fi

    # The list endpoint wraps each item in `{cursor, service}`; a future shape
    # that returns the service flat is tolerated by looking in both places.
    #
    # Only ids that LOOK like a Render service id are kept. An item missing `id`
    # would otherwise reach `jq -r` as the string `null` and be deployed as
    # `/services/null/deploys` -- a request that fails far from its cause.
    PAGE_MATCHES=$(printf '%s' "$LOOKUP_RESPONSE" \
      | jq -r --arg name "$RENDER_SERVICE_NAME" \
          '[.[] | (.service // .)
             | select(.name == $name)
             | .id
             | select(type == "string" and startswith("srv-"))] | .[]')
    if [ -n "$PAGE_MATCHES" ]; then
      MATCHES=$(printf '%s\n%s' "$MATCHES" "$PAGE_MATCHES" | grep -v '^$' | sort -u)
    fi

    PAGE_COUNT=$(printf '%s' "$LOOKUP_RESPONSE" | jq -r 'length')
    if [ "$PAGE_COUNT" -lt "$RENDER_PAGE_SIZE" ]; then
      break
    fi
    CURSOR=$(printf '%s' "$LOOKUP_RESPONSE" | jq -r '.[-1].cursor // empty')
    if [ -z "$CURSOR" ]; then
      # A full page with no cursor to continue from: report the cap rather than
      # claiming the service does not exist.
      echo "WARNING: the service list returned a full page with no cursor; results may be truncated." >&2
      break
    fi
  done

  MATCH_COUNT=$(printf '%s' "$MATCHES" | grep -c . || true)
  if [ "$MATCH_COUNT" -eq 0 ]; then
    echo "ERROR: no web service named '$RENDER_SERVICE_NAME' in this workspace." >&2
    echo "This action deploys an existing service; it does not create one." >&2
    echo "Create it once (dashboard or Blueprint), then re-run -- or pass RENDER_SERVICE_ID." >&2
    exit 1
  fi
  if [ "$MATCH_COUNT" -gt 1 ]; then
    echo "ERROR: '$RENDER_SERVICE_NAME' matched $MATCH_COUNT services:" >&2
    printf '%s\n' "$MATCHES" | while IFS= read -r _match; do
      [ -n "$_match" ] && echo "  $_match" >&2
    done
    echo "Refusing to guess which one to deploy; pass RENDER_SERVICE_ID." >&2
    exit 1
  fi

  RENDER_SERVICE_ID=$MATCHES
  echo "Resolved '$RENDER_SERVICE_NAME' to $RENDER_SERVICE_ID."
fi

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

  # Service-scoped, matching the create call above. Render nests deploys under
  # their service and has NO top-level `/v1/deploys/<id>` resource, so the
  # shorter path 404s. With `fail` set on the curl config that 404 yields empty
  # stdout, `STATUS` stays empty, and the loop below only ever reaches its retry
  # `continue` -- meaning a deploy that actually went live was reported as a
  # timeout failure after the full RENDER_POLL_TIMEOUT, on the very path the
  # docs recommend. See https://api-docs.render.com/reference/retrieve-deploy
  STATUS=$(render_api "GET" "/services/$RENDER_SERVICE_ID/deploys/$DEPLOY_ID" | jq -r '.status // empty')
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
