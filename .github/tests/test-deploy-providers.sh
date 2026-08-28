#!/usr/bin/env bash
set -e

# Test script for the MVP hosting deployment providers
# (global/scripts/deploy/{vercel,cloudflare,netlify,render,flyio}/run.sh) and
# their templates on all three platforms.
#
# Three classes of assertion, each pinning something that would otherwise fail
# silently or late:
#
#   1. STRUCTURAL -- every provider is wired on GitHub Actions, GitLab CI and
#      Azure DevOps, and every template points at the run.sh that actually
#      exists. A provider added to one platform and forgotten on the other two
#      is the single most likely regression in this repository, and nothing else
#      in CI would catch it: each file is valid YAML on its own.
#
#   2. FUNCTIONAL -- each provider is executed in DEPLOY_DRY_RUN mode and the
#      argv it builds is asserted against. This checks what the CLI is actually
#      told rather than what the script looks like it says, the same technique
#      test-dependency-check.sh uses against a stub build tool. The dry run is
#      hermetic: no CLI is installed, no network is touched, no credential is
#      real.
#
#   3. SECURITY -- no credential may reach the recorded command line. Every
#      report directory here is published as a job artifact on all three
#      platforms, so a token on argv would be both visible in `ps` on a
#      self-hosted runner AND persisted into a downloadable artifact for its
#      retention period. Each case below feeds a distinctive sentinel token and
#      greps the whole report directory for it. This is the assertion that must
#      never be relaxed.
#
# The run scripts are invoked as `sh "$RUN_SH"` rather than executed directly.
# They declare `#!/usr/bin/env sh`, so this is faithful to their own shebang,
# and it keeps the suite runnable on hosts where `/usr/bin/env` sits elsewhere.
# The executable bit is asserted separately below (and by the CI job's own
# permission check).

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1"
  local condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_equals() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    echo -e "${RED}        expected: $expected${NC}"
    echo -e "${RED}        actual:   $actual${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PROVIDERS=(vercel cloudflare netlify render flyio)

# Declared here rather than beside their first use: these paths are read from
# several sections, and a variable defined inside a later section expands to
# empty in an earlier one -- which makes `grep` search stdin and the assertion
# fail for a reason that has nothing to do with the code under test.
RENDER_SH="$SCRIPTS_DIR/global/scripts/deploy/render/run.sh"
FLYIO_SH="$SCRIPTS_DIR/global/scripts/deploy/flyio/run.sh"

# A value that cannot plausibly occur anywhere else, so a grep hit in the report
# directory is unambiguously a leak of the credential it was fed as.
SENTINEL='s3nt1nel-must-never-be-recorded'

# Runs one provider in dry-run mode inside a throwaway project directory, then
# leaves the recorded command line in $CMD, stdout+stderr in $OUT, the exit
# status in $STATUS, and the report directory path in $REPORT_DIR.
run_provider() {
  local provider="$1"
  shift

  local projectDir="$WORK_DIR/project"
  rm -rf "$projectDir"
  mkdir -p "$projectDir"

  STATUS=0
  (
    cd "$projectDir"
    # Clear every variable this family reads so each case starts from a known
    # state rather than inheriting the previous one's configuration.
    unset VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID VERCEL_WORKING_DIRECTORY \
      VERCEL_COMMERCIAL VERCEL_PLAN \
      CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_TARGET \
      CLOUDFLARE_PROJECT_NAME CLOUDFLARE_OUTPUT_DIRECTORY CLOUDFLARE_BRANCH \
      CLOUDFLARE_PRODUCTION_BRANCH CLOUDFLARE_API_URL \
      NETLIFY_AUTH_TOKEN NETLIFY_SITE_ID NETLIFY_OUTPUT_DIRECTORY NETLIFY_DEPLOY_MESSAGE \
      RENDER_API_KEY RENDER_SERVICE_ID RENDER_SERVICE_NAME RENDER_DEPLOY_HOOK_URL \
      FLY_API_TOKEN FLY_APP_NAME FLY_ORG FLY_CONFIG FLY_STRATEGY \
      DEPLOY_ENVIRONMENT
    export SCRIPTS_DIR
    export DEPLOY_DRY_RUN=true
    env "$@" sh "$SCRIPTS_DIR/global/scripts/deploy/$provider/run.sh"
  ) > "$projectDir/out.txt" 2>&1 || STATUS=$?

  REPORT_DIR="$projectDir/build/reports/deploy-$provider"
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions, which ShellCheck cannot see
  OUT="$(cat "$projectDir/out.txt")"
  if [[ -f "$REPORT_DIR/command.txt" ]]; then
    CMD="$(cat "$REPORT_DIR/command.txt")"
  else
    CMD=""
  fi
}

# Greps the entire report directory for the sentinel. Covers command.txt and
# deployment.json alike, so a future field that echoes configuration verbatim is
# caught too rather than only the file this test was written against.
assert_no_leak() {
  local description="$1"
  if [[ -d "$REPORT_DIR" ]] && grep -rq "$SENTINEL" "$REPORT_DIR"; then
    echo -e "${RED}  FAIL: $description${NC}"
    echo -e "${RED}        the sentinel credential was recorded in $REPORT_DIR${NC}"
    grep -rn "$SENTINEL" "$REPORT_DIR" | sed 's/^/          /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

echo "Testing MVP hosting deployment providers..."
echo ""

# ---------------------------------------------------------------------------
echo "1. Structural: every provider is wired on all three platforms"
# ---------------------------------------------------------------------------
for provider in "${PROVIDERS[@]}"; do
  runSh="$SCRIPTS_DIR/global/scripts/deploy/$provider/run.sh"
  ghAction="$SCRIPTS_DIR/github/global/stages/50-deployment/$provider/action.yaml"
  glTemplate="$SCRIPTS_DIR/gitlab/global/stages/50-deployment/$provider.yaml"
  adoTemplate="$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/$provider.yaml"

  assert_true "$provider: run.sh exists" "[[ -f '$runSh' ]]"
  assert_true "$provider: run.sh is executable" "[[ -x '$runSh' ]]"
  assert_true "$provider: GitHub Actions composite action exists" "[[ -f '$ghAction' ]]"
  assert_true "$provider: GitLab CI template exists" "[[ -f '$glTemplate' ]]"
  assert_true "$provider: Azure DevOps template exists" "[[ -f '$adoTemplate' ]]"

  # Each template must invoke the provider's own script. A copy-paste that left
  # a sibling provider's path behind would otherwise deploy the wrong thing.
  assert_true "$provider: GitHub action calls its own run.sh" \
    "grep -q 'global/scripts/deploy/$provider/run.sh' '$ghAction'"
  assert_true "$provider: GitLab template calls its own run.sh" \
    "grep -q 'global/scripts/deploy/$provider/run.sh' '$glTemplate'"
  assert_true "$provider: Azure template calls its own run.sh" \
    "grep -q 'global/scripts/deploy/$provider/run.sh' '$adoTemplate'"

  # Every provider must expose the dry-run switch on every platform, otherwise
  # this suite could not exercise it through the templates consumers actually use.
  assert_true "$provider: GitHub action forwards DEPLOY_DRY_RUN" \
    "grep -q 'DEPLOY_DRY_RUN' '$ghAction'"
  assert_true "$provider: Azure template forwards DEPLOY_DRY_RUN" \
    "grep -q 'DEPLOY_DRY_RUN' '$adoTemplate'"
done
echo ""

# ---------------------------------------------------------------------------
echo "2. Functional: Vercel"
# ---------------------------------------------------------------------------
run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1
assert_equals "vercel: production deploy targets the production alias" \
  "vercel deploy --yes --prod" "$CMD"
assert_true "vercel: exits cleanly on a dry run" "[[ $STATUS -eq 0 ]]"
assert_no_leak "vercel: the access token is never recorded"

run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1 \
  DEPLOY_ENVIRONMENT=preview
assert_equals "vercel: a non-production environment omits --prod (preview deploy)" \
  "vercel deploy --yes" "$CMD"

run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1 \
  VERCEL_WORKING_DIRECTORY=apps/web
assert_equals "vercel: a monorepo sub-directory is passed through" \
  "vercel deploy --yes --prod --cwd apps/web" "$CMD"

# The Hobby tier is non-commercial only; the warning is the only thing standing
# between a monetised MVP and a licence violation it finds out about later.
run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1 \
  VERCEL_COMMERCIAL=true
assert_true "vercel: commercial use on the Hobby plan warns about the licence" \
  "grep -q 'non-commercial' <<< \"\$OUT\""

run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1 \
  VERCEL_COMMERCIAL=true VERCEL_PLAN=pro
assert_true "vercel: the licence warning is silenced on the Pro plan" \
  "! grep -q 'non-commercial' <<< \"\$OUT\""

run_provider vercel VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1
assert_true "vercel: a missing token fails the job" "[[ $STATUS -eq 1 ]]"
assert_true "vercel: the failure names the variable to set" \
  "grep -q 'VERCEL_TOKEN is not set' <<< \"\$OUT\""

# Without these the CLI prompts to link a project; on a runner there is no TTY
# to answer, so the job hangs or creates a stray project.
run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1
assert_true "vercel: a missing project id fails rather than prompting" "[[ $STATUS -eq 1 ]]"
echo ""

# ---------------------------------------------------------------------------
echo "3. Functional: Cloudflare"
# ---------------------------------------------------------------------------
run_provider cloudflare CLOUDFLARE_API_TOKEN="$SENTINEL" CLOUDFLARE_ACCOUNT_ID=acc_1 \
  CLOUDFLARE_PROJECT_NAME=my-mvp CLOUDFLARE_BRANCH=main
assert_equals "cloudflare: Pages uploads the build output to the named project" \
  "wrangler pages deploy dist --project-name my-mvp --branch main" "$CMD"
assert_no_leak "cloudflare: the API token is never recorded"

run_provider cloudflare CLOUDFLARE_API_TOKEN="$SENTINEL" CLOUDFLARE_ACCOUNT_ID=acc_1 \
  CLOUDFLARE_PROJECT_NAME=my-mvp CLOUDFLARE_OUTPUT_DIRECTORY=build
assert_equals "cloudflare: a custom output directory is honoured" \
  "wrangler pages deploy build --project-name my-mvp" "$CMD"

# `--env production` requires an [env.production] section in wrangler.toml, so
# sending it unconditionally would break every project using the plain
# top-level configuration.
run_provider cloudflare CLOUDFLARE_TARGET=workers CLOUDFLARE_API_TOKEN="$SENTINEL" \
  CLOUDFLARE_ACCOUNT_ID=acc_1
assert_equals "cloudflare: Workers production omits --env" "wrangler deploy" "$CMD"

run_provider cloudflare CLOUDFLARE_TARGET=workers CLOUDFLARE_API_TOKEN="$SENTINEL" \
  CLOUDFLARE_ACCOUNT_ID=acc_1 DEPLOY_ENVIRONMENT=staging
assert_equals "cloudflare: a named Workers environment is selected with --env" \
  "wrangler deploy --env staging" "$CMD"

run_provider cloudflare CLOUDFLARE_TARGET=nonsense CLOUDFLARE_API_TOKEN="$SENTINEL" \
  CLOUDFLARE_ACCOUNT_ID=acc_1
assert_true "cloudflare: an unknown target fails instead of guessing" "[[ $STATUS -eq 1 ]]"

run_provider cloudflare CLOUDFLARE_API_TOKEN="$SENTINEL" CLOUDFLARE_ACCOUNT_ID=acc_1
assert_true "cloudflare: Pages without a project name fails the job" "[[ $STATUS -eq 1 ]]"

# A Pages project must exist before anything can be uploaded to it, and
# `wrangler pages deploy` will not create one. The check that closes that gap
# talks to the real API, so it has to stay behind the dry-run guard -- it would
# otherwise be the only part of this family that needs a network and a live
# credential, and this suite has neither.
run_provider cloudflare CLOUDFLARE_API_TOKEN="$SENTINEL" CLOUDFLARE_ACCOUNT_ID=acc_1 \
  CLOUDFLARE_PROJECT_NAME=my-mvp
assert_true "cloudflare: the project existence check is skipped on a dry run" \
  "grep -q 'skipping the existence check' <<< \"\$OUT\""
assert_equals "cloudflare: the existence check leaves the deploy command untouched" \
  "wrangler pages deploy dist --project-name my-mvp" "$CMD"
assert_no_leak "cloudflare: the existence check never records the API token"

# Workers have no production branch and no project to create, so the check must
# not run for that target at all.
run_provider cloudflare CLOUDFLARE_TARGET=workers CLOUDFLARE_API_TOKEN="$SENTINEL" \
  CLOUDFLARE_ACCOUNT_ID=acc_1
assert_true "cloudflare: Workers never consult the Pages project check" \
  "! grep -q 'existence check' <<< \"\$OUT\""

# The production branch and the deployment label are different questions.
# Creating a project with the deployment label would make a preview branch the
# project's production branch, publishing every preview to the production URL,
# so the two must never collapse into one variable.
CLOUDFLARE_SH="$SCRIPTS_DIR/global/scripts/deploy/cloudflare/run.sh"
assert_true "cloudflare: project creation uses CLOUDFLARE_PRODUCTION_BRANCH, not CLOUDFLARE_BRANCH" \
  "grep -A2 'pages project create' '$CLOUDFLARE_SH' | grep -q 'CLOUDFLARE_PRODUCTION_BRANCH'"
assert_true "cloudflare: GitHub action forwards CLOUDFLARE_PRODUCTION_BRANCH" \
  "grep -q 'CLOUDFLARE_PRODUCTION_BRANCH' '$SCRIPTS_DIR/github/global/stages/50-deployment/cloudflare/action.yaml'"
assert_true "cloudflare: Azure template forwards CLOUDFLARE_PRODUCTION_BRANCH" \
  "grep -q 'CLOUDFLARE_PRODUCTION_BRANCH' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/cloudflare.yaml'"
assert_true "cloudflare: GitLab template documents CLOUDFLARE_PRODUCTION_BRANCH" \
  "grep -q 'CLOUDFLARE_PRODUCTION_BRANCH' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/cloudflare.yaml'"
echo ""

# ---------------------------------------------------------------------------
echo "4. Functional: Netlify"
# ---------------------------------------------------------------------------
run_provider netlify NETLIFY_AUTH_TOKEN="$SENTINEL" NETLIFY_SITE_ID=site_1
assert_equals "netlify: production publishes the built directory to the live site" \
  "netlify deploy --dir dist --site site_1 --no-build --prod" "$CMD"
assert_no_leak "netlify: the auth token is never recorded"

# Building on Netlify would draw down the 300 credit/month pool a second time
# for work the CI runner has already done.
assert_true "netlify: --no-build keeps the build off Netlify's metered compute" \
  "grep -q -- '--no-build' <<< \"\$CMD\""

run_provider netlify NETLIFY_AUTH_TOKEN="$SENTINEL" NETLIFY_SITE_ID=site_1 \
  DEPLOY_ENVIRONMENT=preview
assert_equals "netlify: a non-production environment creates a draft deploy" \
  "netlify deploy --dir dist --site site_1 --no-build" "$CMD"

run_provider netlify NETLIFY_AUTH_TOKEN="$SENTINEL"
assert_true "netlify: a missing site id fails the job" "[[ $STATUS -eq 1 ]]"
echo ""

# ---------------------------------------------------------------------------
echo "5. Functional: Render"
# ---------------------------------------------------------------------------
run_provider render RENDER_API_KEY="$SENTINEL" RENDER_SERVICE_ID=srv_1
assert_true "render: the API path posts to the service's deploys endpoint" \
  "grep -q 'services/srv_1/deploys' <<< \"\$CMD\""
assert_no_leak "render: the API key is never recorded"

# The hook URL embeds its own secret key in the query string, so the whole URL
# is a credential and must be redacted rather than recorded.
run_provider render RENDER_DEPLOY_HOOK_URL="https://api.render.com/deploy/srv_1?key=$SENTINEL"
assert_true "render: the deploy hook URL is redacted, not recorded" \
  "grep -q 'redacted' <<< \"\$CMD\""
assert_no_leak "render: the deploy hook's embedded key is never recorded"

# A deploy hook cannot report the build result, so the job would go green on a
# broken deploy. Consumers must be told that in the log.
assert_true "render: the deploy-hook path warns that it cannot fail on a bad deploy" \
  "grep -q 'cannot fail' <<< \"\$OUT\""

run_provider render RENDER_API_KEY="$SENTINEL"
assert_true "render: an API key with neither a service id nor a name fails the job" \
  "[[ $STATUS -eq 1 ]]"
assert_true "render: that failure names both ways to identify the service" \
  "grep -q 'RENDER_SERVICE_NAME' <<< \"\$OUT\""

# A name is resolved through the API, which a dry run must not call: resolution
# is a read, but it still needs a live key and a reachable Render, and every
# provider in this suite runs under DEPLOY_DRY_RUN. Without the guard this case
# reaches out to api.render.com with the sentinel token.
run_provider render RENDER_API_KEY="$SENTINEL" RENDER_SERVICE_NAME=api-staging
assert_true "render: a service name is accepted in place of an id" "[[ $STATUS -eq 0 ]]"
assert_true "render: a dry run records the lookup instead of performing it" \
  "grep -q 'DRY RUN (no lookup performed)' <<< \"\$OUT\""
assert_true "render: the dry-run receipt names the service that would be resolved" \
  "grep -q 'api-staging' <<< \"\$CMD\" || grep -q 'api-staging' <<< \"\$OUT\""
assert_no_leak "render: the API key is never recorded while resolving a name"

# Exercise `render_api` directly with curl stubbed to echo its config. A GET
# carrying a request body is rejected outright by some servers and proxies,
# which would fail the polling loop for a reason unrelated to the deploy it is
# reporting on -- and the error would point at Render rather than at this
# script. Also confirms the bearer token actually interpolates: a format string
# that lost its `%s` would authenticate as a literal and 401 on every call.
RENDER_PROBE="$WORK_DIR/render-probe.sh"
{
  echo 'RENDER_API_URL="https://api.render.com/v1"'
  echo 'RENDER_API_KEY="probe-token"'
  echo 'curl() { cat; }'
  sed -n '/^render_api() {/,/^}/p' "$SCRIPTS_DIR/global/scripts/deploy/render/run.sh"
  echo 'echo "===POST==="; render_api POST /services/srv-1/deploys'
  echo 'echo "===GET==="; render_api GET /deploys/dep-1'
} > "$RENDER_PROBE"
RENDER_PROBE_OUT="$(sh "$RENDER_PROBE")"
# shellcheck disable=SC2034  # both are read by assert_true's eval'd conditions below
RENDER_POST_CFG="$(sed -n '/===POST===/,/===GET===/p' <<< "$RENDER_PROBE_OUT")"
# shellcheck disable=SC2034  # read by assert_true's eval'd conditions below
RENDER_GET_CFG="$(sed -n '/===GET===/,$p' <<< "$RENDER_PROBE_OUT")"

assert_true "render: the POST that creates a deploy sends a JSON body" \
  "grep -q 'data = ' <<< \"\$RENDER_POST_CFG\""
assert_true "render: the GET poll sends no request body" \
  "! grep -q 'data = ' <<< \"\$RENDER_GET_CFG\""
assert_true "render: the GET poll sends no Content-Type" \
  "! grep -q 'Content-Type' <<< \"\$RENDER_GET_CFG\""
assert_true "render: the bearer token interpolates rather than staying a literal" \
  "grep -q 'Authorization: Bearer probe-token' <<< \"\$RENDER_POST_CFG\""

# Render nests deploys under their service and has NO top-level
# `/v1/deploys/<id>`. Polling the short path 404s, and because the curl config
# sets `fail` the 404 yields empty stdout -- so the loop never leaves its retry
# branch and a deploy that actually went live is reported as a timeout failure
# after the full RENDER_POLL_TIMEOUT, on the path the docs call preferred.
# shellcheck disable=SC2034  # read by assert_true's eval'd condition below
RENDER_POLL_PATTERN='render_api "GET" "/services/$RENDER_SERVICE_ID/deploys/$DEPLOY_ID"'
assert_true "render: the status poll is service-scoped, not top-level" \
  "grep -qF \"\$RENDER_POLL_PATTERN\" '$RENDER_SH'"
assert_true "render: no call targets the non-existent top-level /deploys path" \
  "! sed 's/#.*//' '$RENDER_SH' | grep -qE 'render_api \"GET\" \"/deploys/'"

run_provider render
assert_true "render: neither credential set fails the job" "[[ $STATUS -eq 1 ]]"
assert_true "render: the failure explains both configuration options" \
  "grep -q 'RENDER_DEPLOY_HOOK_URL' <<< \"\$OUT\""
echo ""

# ---------------------------------------------------------------------------
echo "6. Functional: Fly.io"
# ---------------------------------------------------------------------------
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp
assert_equals "flyio: the app is deployed with a remote build" \
  "flyctl deploy --remote-only --app my-mvp" "$CMD"
assert_no_leak "flyio: the API token is never recorded"

# `--remote-only` is what lets this job run without a Docker daemon, which most
# GitLab and Azure DevOps agents do not provide.
assert_true "flyio: --remote-only avoids requiring Docker on the runner" \
  "grep -q -- '--remote-only' <<< \"\$CMD\""

run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_STRATEGY=bluegreen
assert_equals "flyio: a deployment strategy is passed through" \
  "flyctl deploy --remote-only --app my-mvp --strategy bluegreen" "$CMD"

run_provider flyio FLY_APP_NAME=my-mvp
assert_true "flyio: a missing token fails the job" "[[ $STATUS -eq 1 ]]"

# flyctl is installed from the GitHub release archive, never by piping a remote
# script into a shell -- the supply-chain shape this repository's own SAST stage
# exists to flag. Comment lines are stripped first: the script documents the
# rejected `curl ... | sh` one-liner in prose, and matching that would fail the
# assertion on the very comment explaining why the code does not do it.
assert_true "flyio: the CLI is not installed by piping a remote script to a shell" \
  "! sed 's/#.*//' '$SCRIPTS_DIR/global/scripts/deploy/flyio/run.sh' | grep -qE 'curl[^|]*\\|[[:space:]]*(ba)?sh'"

# App auto-creation (FLY_ORG). `flyctl deploy` does not create apps, so a new
# environment's first run is red without this; it is opt-in because it forces an
# ORG-SCOPED token, an app-scoped one being unable to create apps.
#
# The dry run is the assertion that keeps this suite hermetic: FLY_ORG set must
# still reach the same deploy argv and must not shell out to `flyctl apps` --
# the harness has no credentials and no network, and a creation attempt here
# would be the one step in this family that tried to use them.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_ORG=my-org
assert_equals "flyio: FLY_ORG does not change the deploy that is performed" \
  "flyctl deploy --remote-only --app my-mvp" "$CMD"
assert_true "flyio: a dry run never attempts to create the app" \
  "! grep -q 'creating it in org' <<< \"\$OUT\""
assert_no_leak "flyio: the API token is never recorded with FLY_ORG set"

# `command.txt` must end the job holding the DEPLOY command -- it is the first
# thing anyone debugging a red deploy reads. Routing the creation through
# `deploy_run` would overwrite it with `apps create`, so the creation deliberately
# calls flyctl directly and this pins that it stays that way.
#
# Asserted on the SOURCE, not on command.txt: `run_provider` always exports
# DEPLOY_DRY_RUN=true and the creation is gated on `! deploy_is_dry_run`, so
# `apps create` is unreachable under this harness and the file could never hold
# it however the creation were written. An assertion that reads as functional
# and cannot fail is worse than none -- it reports coverage the feature does
# not have.
assert_true "flyio: creating the app does not overwrite the recorded deploy command" \
  "! grep -q 'deploy_run.*apps create' '$FLYIO_SH'"

# A FAILED lookup must not read as "the app does not exist": swallowing flyctl's
# status and diagnostic turned an API error into a bogus creation attempt, which
# fails on the name being taken and advises widening a token that was already
# wide enough.
assert_true "flyio: a failed app lookup is not treated as the app being absent" \
  "grep -q 'could not list Fly apps' '$FLYIO_SH'"

# The app name has TWO documented sources, and gating the creation on
# FLY_APP_NAME alone made FLY_ORG a silent no-op for the other one: an `app`
# declared in fly.toml, which is exactly the configuration `go-flyio.yaml`
# describes as making `fly_app_name` optional. The config lives outside the
# project directory because `run_provider` wipes that directory before each run.
printf 'app = "app-from-toml"\nprimary_region = "yyz"\n' > "$WORK_DIR/fly-from-toml.toml"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_CONFIG="$WORK_DIR/fly-from-toml.toml" FLY_ORG=my-org
assert_true "flyio: an app name declared in fly.toml resolves, so FLY_ORG is not a no-op" \
  "! grep -q 'no app name could be resolved' <<< \"\$OUT\""
# ...and resolving it must not leak into the deploy: fly.toml already carries the
# name, so an added `--app` would change the deploy of every consumer using it.
assert_equals "flyio: an app name read from fly.toml does not add --app to the deploy" \
  "flyctl deploy --remote-only --config $WORK_DIR/fly-from-toml.toml" "$CMD"

# And when neither source yields a name, opting in must SAY so. Skipping in
# silence is the failure this whole feature exists to remove, now paid for with
# a wider token.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_ORG=my-org
assert_true "flyio: FLY_ORG with no resolvable app name warns instead of skipping silently" \
  "grep -q 'FLY_ORG is set but no app name could be resolved' <<< \"\$OUT\""

# Both guards, asserted on the source: without FLY_ORG the step is skipped (which
# is what keeps app-scoped tokens viable), and without the dry-run guard this
# suite could not run offline.
assert_true "flyio: app creation is gated on FLY_ORG being set" \
  "grep -q 'FLY_ORG:-' '$FLYIO_SH'"
assert_true "flyio: app creation is skipped on a dry run" \
  "grep -q 'deploy_is_dry_run' '$FLYIO_SH'"

# Existence is checked before creating. Fly app names are GLOBALLY unique, so
# 'create and ignore the error' would report success against an app owned by an
# unrelated organisation.
assert_true "flyio: the app is looked up before it is created" \
  "grep -q 'apps list --json' '$FLYIO_SH'"

# A refused `apps create` has two unrelated causes needing opposite fixes, and the
# first version of this block advised the token fix for both. A globally-taken name
# is the likelier one for any unprefixed name, and no credential can resolve it.
assert_true "flyio: a create failure distinguishes a taken name from a narrow token" \
  "grep -q 'already been taken' '$FLYIO_SH'"
assert_true "flyio: a taken name is not reported as a token problem" \
  "grep -q 'NOT a token problem' '$FLYIO_SH'"
assert_true "flyio: the app-scoped-token hint survives for every other failure" \
  "grep -q 'tokens create org' '$FLYIO_SH'"

# The cross-platform wiring contract, applied to the new variable: a knob added
# on one platform and forgotten on the other two leaves three files that are each
# valid YAML on their own, which nothing else in CI would catch.
assert_true "flyio: GitHub action forwards FLY_ORG" \
  "grep -q 'FLY_ORG' '$SCRIPTS_DIR/github/global/stages/50-deployment/flyio/action.yaml'"
assert_true "flyio: Azure template forwards FLY_ORG" \
  "grep -q 'FLY_ORG' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/flyio.yaml'"
assert_true "flyio: GitLab template documents FLY_ORG" \
  "grep -q 'FLY_ORG' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/flyio.yaml'"
assert_true "flyio: the reusable workflow exposes fly_org" \
  "grep -q 'fly_org' '$SCRIPTS_DIR/.github/workflows/go-flyio.yaml'"

# Per-environment app naming. A calling job cannot declare `environment:`, so an
# environment-scoped variable can only be NAMED by the caller and read inside the
# job that has the environment -- the same constraint `build_env_vars` carries in
# the Cloudflare workflows. Structural, because the harness exercises run.sh and
# not the reusable workflow.
GO_FLYIO="$SCRIPTS_DIR/.github/workflows/go-flyio.yaml"
assert_true "flyio: the app name can be named as a caller variable" \
  "grep -q 'fly_app_name_var' '$GO_FLYIO'"
assert_true "flyio: the org can be named as a caller variable" \
  "grep -q 'fly_org_var' '$GO_FLYIO'"
assert_true "flyio: the named variable is indexed inside the environment-scoped job" \
  "grep -q 'vars\[inputs.fly_app_name_var\]' '$GO_FLYIO'"
# A literal input must keep winning, or a caller that passes both silently gets the
# variable and cannot tell which one it deployed.
assert_true "flyio: an explicit fly_app_name still wins over the named variable" \
  "grep -q \"inputs.fly_app_name != '' && inputs.fly_app_name || vars\[\" '$GO_FLYIO'"
# An unset variable must fail loudly: an empty app name falls through to whatever
# fly.toml declares, which for a two-app repository is deliberately nothing.
assert_true "flyio: a named variable that resolves to nothing fails the job" \
  "grep -q 'which is not set for this deployment' '$GO_FLYIO'"
# "Opted in and got nothing" must never be silent -- the rule #645 established. The org
# half warns rather than failing, because an org is genuinely optional; what is not
# optional is saying so.
assert_true "flyio: an unresolvable org variable disables auto-creation out loud" \
  "grep -q 'so app auto-creation is disabled here' '$GO_FLYIO'"
# A caller-controlled input spliced into a `run:` body is pasted in before bash parses
# it, so `\$(...)` in the value executes in the job holding FLY_API_TOKEN. Every value
# these steps read must arrive through `env:`.
assert_true "flyio: no workflow_call input is interpolated into a run: body" \
  "! awk '/^ *run:/,/^ *(shell|env|with|if|-|jobs):/' '$GO_FLYIO' | grep -q 'inputs\.'"
echo ""

# ---------------------------------------------------------------------------
echo "7. Deployment record"
# ---------------------------------------------------------------------------
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp
assert_true "record: a deployment.json receipt is written" "[[ -f '$REPORT_DIR/deployment.json' ]]"
assert_true "record: the receipt names the provider" \
  "grep -q '\"provider\": \"flyio\"' '$REPORT_DIR/deployment.json'"
assert_true "record: the receipt marks a dry run as such" \
  "grep -q '\"dry_run\": true' '$REPORT_DIR/deployment.json'"
if command -v python3 > /dev/null 2>&1; then
  assert_true "record: the receipt is valid JSON" \
    "python3 -c \"import json,sys; json.load(open('$REPORT_DIR/deployment.json'))\""
fi
echo ""

# ---------------------------------------------------------------------------
echo "8. Hermetic dry run"
# ---------------------------------------------------------------------------
# A dry run must not install a CLI: the suite has to work offline, on an agent
# with no Node.js toolchain, without downloading ~100 MB per provider.
run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1
assert_true "dry run: no CLI is installed" "grep -q 'skipping installation' <<< \"\$OUT\""
assert_true "dry run: the log states that nothing was deployed" \
  "grep -q 'no deploy performed' <<< \"\$OUT\""
echo ""

# ---------------------------------------------------------------------------
echo "9. Transport pinning"
# ---------------------------------------------------------------------------
# `curl -L` follows a redirect from HTTPS into plain HTTP by default. That
# matters most in the one place it is unavoidable: flyctl's version is resolved
# THROUGH a redirect, and the asset URL redirects to a CDN -- and those bytes
# become a binary this script marks executable and runs with the job's
# credentials in scope. `--proto '=https' --proto-redir '=https'` removes the
# downgrade as an option instead of trusting the remote not to offer it.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  assert_true "flyio: redirect-following curl pins HTTPS -- ${line:0:48}..." \
    "grep -q -- \"--proto-redir '=https'\" <<< \"\$line\""
done < <(sed 's/#.*//' "$FLYIO_SH" | grep -E "curl .*-[a-zA-Z]*L")

# Render's URLs are consumer-supplied (RENDER_API_URL is overridable and the
# deploy hook URL carries its secret in the query string), so a plain-HTTP value
# would put a bearer token or an embedded key on the wire in cleartext.
# Comments are stripped first: the script explains the pinning in prose next to
# each block, and counting those mentions would let the assertion pass on the
# documentation alone even if the code had lost the flag.
RENDER_CODE="$(sed 's/#.*//' "$RENDER_SH")"
RENDER_URL_LINES="$(grep -c 'url = ' <<< "$RENDER_CODE")"
RENDER_PINNED_LINES="$(grep -cF 'proto = "=https"' <<< "$RENDER_CODE")"
assert_equals "render: every curl config block pins the protocol to HTTPS" \
  "$RENDER_URL_LINES" "$RENDER_PINNED_LINES"
assert_true "render: at least one curl config block exists to pin" "[[ $RENDER_URL_LINES -ge 2 ]]"
echo ""

# ---------------------------------------------------------------------------
echo "10. Azure DevOps boolean stringification"
# ---------------------------------------------------------------------------
# Azure DevOps renders a `boolean` template parameter as `True` / `False`
# (PascalCase). A strict `= "true"` test therefore turned a REQUESTED DRY RUN
# INTO A REAL DEPLOY on Azure alone -- the worst direction for this flag to fail
# in -- and `deploy_record` interpolated the raw value, so every Azure deploy
# (including ordinary production runs that never asked for a dry run) wrote a
# receipt containing `"dry_run": False`, which no JSON parser accepts.
#
# Driving the scripts directly could never have caught this: the value only
# takes that spelling once Azure has rendered the template. So the contract is
# pinned from both ends -- the scripts accept the platform's spelling, and the
# templates are asserted to lowercase it.
run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1 \
  DEPLOY_DRY_RUN=True
assert_true "azure: DEPLOY_DRY_RUN=True (PascalCase) is honoured as a dry run" \
  "grep -q 'no deploy performed' <<< \"\$OUT\""
assert_true "azure: a PascalCase dry run still writes a valid-JSON receipt" \
  "python3 -c \"import json; json.load(open('$REPORT_DIR/deployment.json'))\""
assert_true "azure: the receipt normalises True to a JSON boolean" \
  "grep -q '\"dry_run\": true' '$REPORT_DIR/deployment.json'"

# `DEPLOY_DRY_RUN=False` means a REAL deploy, which cannot be driven here, so
# the false branch is probed at `deploy_record` directly rather than through a
# provider. This is the branch that mattered most in practice: it is the one an
# ordinary Azure production run takes, and it was writing `"dry_run": False`
# into every published receipt.
RECORD_PROBE_DIR="$WORK_DIR/record-probe"
rm -rf "$RECORD_PROBE_DIR" && mkdir -p "$RECORD_PROBE_DIR"
(
  REPORT_PATH="$RECORD_PROBE_DIR"
  export REPORT_PATH
  DEPLOY_DRY_RUN=False
  export DEPLOY_DRY_RUN
  # shellcheck disable=SC1091
  . "$SCRIPTS_DIR/global/scripts/deploy/common.sh"
  deploy_record "vercel" "prj_1" > /dev/null
)
assert_true "azure: DEPLOY_DRY_RUN=False (PascalCase) writes valid JSON" \
  "python3 -c \"import json; json.load(open('$RECORD_PROBE_DIR/deployment.json'))\""
assert_true "azure: the receipt normalises False to a JSON boolean" \
  "grep -q '\"dry_run\": false' '$RECORD_PROBE_DIR/deployment.json'"

# The Vercel licence warning is gated on the same kind of flag, so it had the
# same blind spot: on Azure it could never fire.
run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1 \
  VERCEL_COMMERCIAL=True
assert_true "azure: the commercial-use warning fires for PascalCase True" \
  "grep -q 'non-commercial' <<< \"\$OUT\""

for provider in "${PROVIDERS[@]}"; do
  adoTemplate="$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/$provider.yaml"
  assert_true "$provider: the Azure template lowercases DEPLOY_DRY_RUN" \
    "grep -q 'DEPLOY_DRY_RUN: \${{ lower(parameters.DRY_RUN) }}' '$adoTemplate'"
done
assert_true "vercel: the Azure template lowercases VERCEL_COMMERCIAL" \
  "grep -q 'VERCEL_COMMERCIAL: \${{ lower(parameters.COMMERCIAL) }}' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/vercel.yaml'"
echo ""

# ---------------------------------------------------------------------------
echo "11. Functional: require-checks"
# ---------------------------------------------------------------------------
# The gate reads the GitHub API, so `gh` is stubbed with a fixture rather than
# the script being trusted to describe itself. What is asserted is the verdict
# it reaches from a given set of check runs, which is the only thing a caller
# depends on.
REQUIRE_SH="$SCRIPTS_DIR/global/scripts/deploy/require-checks/run.sh"
RC_DIR="$WORK_DIR/require-checks"
mkdir -p "$RC_DIR/stub"
cat > "$RC_DIR/stub/gh" <<'STUB'
#!/bin/sh
cat "$GH_STUB_FIXTURE"
STUB
chmod +x "$RC_DIR/stub/gh"

# Runs the gate against a fixture, leaving the exit status in $RC_STATUS and the
# output in $RC_OUT.
run_require_checks() {
  local fixture="$1"
  RC_STATUS=0
  (
    cd "$RC_DIR"
    PATH="$RC_DIR/stub:$PATH" \
    GH_STUB_FIXTURE="$RC_DIR/$fixture" \
    REQUIRE_CHECKS_NAMES="$(printf 'tests > test:all\ncode-check > style:golangci-lint')" \
    REQUIRE_CHECKS_COMMIT=abc REQUIRE_CHECKS_REPOSITORY=o/r \
    SCRIPTS_DIR="$SCRIPTS_DIR" sh "$REQUIRE_SH"
  ) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
  RC_OUT="$(cat "$RC_DIR/out.txt")"
}

printf '{"name":"tests > test:all","conclusion":"success"}\n{"name":"code-check > style:golangci-lint","conclusion":"success"}\n' > "$RC_DIR/green.json"
printf '{"name":"tests > test:all","conclusion":"success"}\n{"name":"code-check > style:golangci-lint","conclusion":"success"}\n{"name":"deployment > render","conclusion":"failure"}\n{"name":"ping /healthz","conclusion":"failure"}\n' > "$RC_DIR/unrelated.json"
printf '' > "$RC_DIR/empty.json"
printf '{"name":"tests > test:all","conclusion":"failure"}\n{"name":"code-check > style:golangci-lint","conclusion":"success"}\n' > "$RC_DIR/testfail.json"

assert_true "require-checks: run.sh is executable" "[[ -x '$REQUIRE_SH' ]]"
assert_true "require-checks: a GitHub Actions composite action exists" \
  "[[ -f '$SCRIPTS_DIR/github/global/stages/50-deployment/require-checks/action.yaml' ]]"

run_require_checks green.json
assert_true "require-checks: every required check green passes the gate" "[[ $RC_STATUS -eq 0 ]]"

# The reason this gate silently stopped working for one consumer: GitHub composes
# a check's name from the calling job and the called workflow's job, so a stage
# published as `tests > test:all` is RECORDED as `default / go / tests > test:all`
# once it runs through a reusable workflow -- and the prefix changes again if
# either job is renamed. Matching only on equality made every required name read
# as missing, and the deploy could not be made to pass without pasting a prefix
# that is not the caller's to guarantee.
printf '{"name":"default / go / tests > test:all","conclusion":"success"}\n{"name":"default / go / code-check > style:golangci-lint","conclusion":"success"}\n' > "$RC_DIR/prefixed.json"
run_require_checks prefixed.json
assert_true "require-checks: a bare name matches a check GitHub prefixed with its caller" \
  "[[ $RC_STATUS -eq 0 ]]"

# The suffix is anchored on ' / ', so it matches a whole trailing segment and not
# any name that merely ends with the same characters.
printf '{"name":"smoke-tests > test:all","conclusion":"success"}\n{"name":"default / go / code-check > style:golangci-lint","conclusion":"success"}\n' > "$RC_DIR/lookalike.json"
run_require_checks lookalike.json
assert_true "require-checks: a name ending in the same text but not a whole segment does not match" \
  "[[ $RC_STATUS -eq 1 ]]"

# A prefixed check that FAILED must not be rescued by the looser matching.
printf '{"name":"default / go / tests > test:all","conclusion":"failure"}\n{"name":"default / go / code-check > style:golangci-lint","conclusion":"success"}\n' > "$RC_DIR/prefixedfail.json"
run_require_checks prefixedfail.json
assert_true "require-checks: a failed prefixed check still fails the gate" \
  "[[ $RC_STATUS -eq 1 ]]"

# The regression this gate is most likely to grow: every workflow attaches its
# runs to the same commit, so a keep-alive ping or a previous failed deploy must
# not block the deploy -- the second of those would make the gate permanently
# refuse to retry the very job it guards.
run_require_checks unrelated.json
assert_true "require-checks: unrelated failing checks on the same commit are ignored" \
  "[[ $RC_STATUS -eq 0 ]]"

# A commit nobody tested carries no failures either, so absence must fail.
run_require_checks empty.json
assert_true "require-checks: a commit with no check runs is refused" "[[ $RC_STATUS -eq 1 ]]"
assert_true "require-checks: the refusal names the missing check" \
  "grep -q 'no successful .tests > test:all.' <<< \"\$RC_OUT\""

run_require_checks testfail.json
assert_true "require-checks: a failed required check is refused" "[[ $RC_STATUS -eq 1 ]]"

# Dry run must reach a verdict without the API, like every other script here.
RC_STATUS=0
(
  cd "$RC_DIR"
  REQUIRE_CHECKS_NAMES='tests > test:all' REQUIRE_CHECKS_COMMIT=abc \
  REQUIRE_CHECKS_REPOSITORY=o/r DEPLOY_DRY_RUN=true \
  SCRIPTS_DIR="$SCRIPTS_DIR" sh "$REQUIRE_SH"
) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
RC_OUT="$(cat "$RC_DIR/out.txt")"
assert_true "require-checks: a dry run exits cleanly without calling the API" "[[ $RC_STATUS -eq 0 ]]"
assert_true "require-checks: a dry run lists what it would require" \
  "grep -q 'tests > test:all' <<< \"\$RC_OUT\""

# "Hermetic" has to mean without the binaries too, not merely without the
# network. The rest of this section runs on a machine that happens to have `gh`
# and `jq` installed, so an availability check sitting above the dry-run exit
# would pass every assertion here and still fail on a runner that has neither.
# This builds a PATH holding only what the dry-run path genuinely uses and
# asserts the verdict is still reached.
RC_BIN="$RC_DIR/minimal-bin"
mkdir -p "$RC_BIN"
for tool in sh dirname realpath sed rm mkdir tr cat env; do
  for dir in /bin /usr/bin; do
    if [[ -x "$dir/$tool" ]]; then ln -sf "$dir/$tool" "$RC_BIN/$tool"; break; fi
  done
done

RC_STATUS=0
(
  cd "$RC_DIR"
  env -i PATH="$RC_BIN" HOME="$RC_DIR" \
    REQUIRE_CHECKS_NAMES='tests > test:all' REQUIRE_CHECKS_COMMIT=abc \
    REQUIRE_CHECKS_REPOSITORY=o/r DEPLOY_DRY_RUN=true SCRIPTS_DIR="$SCRIPTS_DIR" \
    "$RC_BIN/sh" "$REQUIRE_SH"
) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
RC_OUT="$(cat "$RC_DIR/out.txt")"
assert_true "require-checks: a dry run needs neither gh nor jq on PATH" "[[ $RC_STATUS -eq 0 ]]"

# The check must still exist, just later: a real run without the binaries has to
# say so rather than fail somewhere further down with a confusing error.
RC_STATUS=0
(
  cd "$RC_DIR"
  env -i PATH="$RC_BIN" HOME="$RC_DIR" \
    REQUIRE_CHECKS_NAMES='tests > test:all' REQUIRE_CHECKS_COMMIT=abc \
    REQUIRE_CHECKS_REPOSITORY=o/r SCRIPTS_DIR="$SCRIPTS_DIR" \
    "$RC_BIN/sh" "$REQUIRE_SH"
) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
RC_OUT="$(cat "$RC_DIR/out.txt")"
assert_true "require-checks: a real run with nothing on PATH names the missing parser" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q \"'jq' is required\" <<< \"\$RC_OUT\""

# Separately, because the parser is checked before the transport and would
# otherwise mask it: a runner that HAS jq but neither client has to be told
# which two things would satisfy it, not just that one of them is absent.
RC_NOTRANSPORT_BIN="$RC_DIR/no-transport-bin"
mkdir -p "$RC_NOTRANSPORT_BIN"
for tool in sh dirname realpath sed rm mkdir tr cat env jq; do
  for dir in /bin /usr/bin; do
    if [[ -x "$dir/$tool" ]]; then ln -sf "$dir/$tool" "$RC_NOTRANSPORT_BIN/$tool"; break; fi
  done
done
RC_STATUS=0
(
  cd "$RC_DIR"
  env -i PATH="$RC_NOTRANSPORT_BIN" HOME="$RC_DIR" \
    REQUIRE_CHECKS_NAMES='tests > test:all' REQUIRE_CHECKS_COMMIT=abc \
    REQUIRE_CHECKS_REPOSITORY=o/r SCRIPTS_DIR="$SCRIPTS_DIR" \
    "$RC_NOTRANSPORT_BIN/sh" "$REQUIRE_SH"
) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
RC_OUT="$(cat "$RC_DIR/out.txt")"
assert_true "require-checks: jq present but no client names both transports" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q \"needs either 'gh' or 'curl'\" <<< \"\$RC_OUT\""

# The gate used to REQUIRE `gh`, and that is how it failed on the first consumer
# to run it: `gh` ships on GitHub-hosted runners and on almost no self-hosted
# one, so a self-hosted deploy died at the very first step of its deployment,
# after the whole pipeline had already passed, with a message about a CLI it had
# no reason to have installed. `curl` and `jq` were already assumed by
# `render/run.sh` in the same job, so the fallback costs nothing.
#
# Stubbed as the REST endpoint rather than as `gh`: what has to be proven is
# that the OTHER transport reaches the same verdict from the shape the API
# actually returns, which is `{"total_count":N,"check_runs":[...]}` and not the
# line-delimited projection `gh --jq` produces.
RC_CURL_BIN="$RC_DIR/curl-only-bin"
mkdir -p "$RC_CURL_BIN"
for tool in sh dirname realpath sed rm mkdir tr cat env jq printf; do
  for dir in /bin /usr/bin; do
    if [[ -x "$dir/$tool" ]]; then ln -sf "$dir/$tool" "$RC_CURL_BIN/$tool"; break; fi
  done
done
cat > "$RC_CURL_BIN/curl" <<'STUB'
#!/bin/sh
cat "$CURL_STUB_FIXTURE"
STUB
chmod +x "$RC_CURL_BIN/curl"

printf '{"total_count":2,"check_runs":[{"name":"default / go / tests > test:all","conclusion":"success"},{"name":"code-check > style:golangci-lint","conclusion":"success"}]}' \
  > "$RC_DIR/rest-green.json"
printf '{"total_count":2,"check_runs":[{"name":"tests > test:all","conclusion":"failure"},{"name":"code-check > style:golangci-lint","conclusion":"success"}]}' \
  > "$RC_DIR/rest-red.json"

run_require_checks_curl() {
  local fixture="$1"
  RC_STATUS=0
  (
    cd "$RC_DIR"
    env -i PATH="$RC_CURL_BIN" HOME="$RC_DIR" \
      CURL_STUB_FIXTURE="$RC_DIR/$fixture" GH_TOKEN=fixture-token-placeholder \
      REQUIRE_CHECKS_NAMES="$(printf 'tests > test:all\ncode-check > style:golangci-lint')" \
      REQUIRE_CHECKS_COMMIT=abc REQUIRE_CHECKS_REPOSITORY=o/r SCRIPTS_DIR="$SCRIPTS_DIR" \
      "$RC_CURL_BIN/sh" "$REQUIRE_SH"
  ) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
  RC_OUT="$(cat "$RC_DIR/out.txt")"
}

run_require_checks_curl rest-green.json
assert_true "require-checks: the curl transport passes the gate with no gh on PATH" \
  "[[ $RC_STATUS -eq 0 ]]"
assert_true "require-checks: the curl transport says which transport it used" \
  "grep -q \"through 'curl'\" <<< \"\$RC_OUT\""
assert_true "require-checks: the curl transport still matches a prefixed check name" \
  "grep -q 'OK: tests > test:all' <<< \"\$RC_OUT\""

run_require_checks_curl rest-red.json
assert_true "require-checks: the curl transport refuses a failed required check" \
  "[[ $RC_STATUS -eq 1 ]]"

# Without a token there is nothing to authenticate with, and the API answers 401
# for a private repository -- which would otherwise surface as "no successful
# check", i.e. as a commit that failed rather than as a misconfiguration.
RC_STATUS=0
(
  cd "$RC_DIR"
  env -i PATH="$RC_CURL_BIN" HOME="$RC_DIR" \
    CURL_STUB_FIXTURE="$RC_DIR/rest-green.json" \
    REQUIRE_CHECKS_NAMES='tests > test:all' \
    REQUIRE_CHECKS_COMMIT=abc REQUIRE_CHECKS_REPOSITORY=o/r SCRIPTS_DIR="$SCRIPTS_DIR" \
    "$RC_CURL_BIN/sh" "$REQUIRE_SH"
) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
# Read back through `assert_true`, whose condition is a STRING it `eval`s, so ShellCheck sees
# `\$RC_OUT` as literal text and reports the assignment as unused. Scoped to this one
# assignment rather than to the file, so a genuinely dead variable is still reported.
# shellcheck disable=SC2034
RC_OUT="$(cat "$RC_DIR/out.txt")"
assert_true "require-checks: the curl transport names a missing token instead of reporting a red commit" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q 'no token available' <<< \"\$RC_OUT\""

# ...and stops there. Exit 1 alone proves nothing about WHICH refusal happened:
# an empty check list also exits 1, by way of "no successful check", so the
# assertion above passed for years while the transport error was in fact being
# discarded. The pipeline `fetch | jq -s '.'` reported jq's status, and `jq -s`
# answers `[]` on empty input, so a token that was never there read as a commit
# whose tests had failed. This is the half that can tell the two apart.
assert_true "require-checks: a transport refusal is not reported as a red commit" \
  "! grep -q 'no successful' <<< \"\$RC_OUT\""

# A RENAMED owner or repository is the one API answer this gate cannot afford to
# misread. GitHub answers **301** for it -- not 404 -- and `curl -f` lets a 3xx
# through, so the redirect body ({"message":"Moved Permanently","url":...}) was
# parsed as the answer: `.check_runs` read as null, `length` answered 0, and the
# gate refused a commit on which every required check was green. `github.repository`
# is fixed when the run is CREATED and the deploy is the last job in it, so a
# rename during a long pipeline is enough to hit this, and the job's log blames
# the repository's tests for a change made in an organisation's settings.
#
# The fix is `curl -L` (with the redirect confined to https), which the stub here
# cannot exercise -- it answers whatever fixture it is handed, following nothing.
# What IS asserted is the guard behind it: any payload without a `check_runs`
# array is refused loudly instead of being folded into an empty list, so every
# other unreadable answer -- an error envelope, a proxy's HTML, a truncated body
# -- fails as the misconfiguration it is.
printf '{"message":"Moved Permanently","url":"https://api.github.com/repositories/1/commits/abc/check-runs","documentation_url":"https://docs.github.com/rest"}' \
  > "$RC_DIR/rest-moved.json"
run_require_checks_curl rest-moved.json
assert_true "require-checks: a redirect body is refused rather than read as an empty check list" \
  "[[ $RC_STATUS -eq 1 ]]"
assert_true "require-checks: the redirect refusal repeats what the API said" \
  "grep -q 'Moved Permanently' <<< \"\$RC_OUT\""
assert_true "require-checks: the redirect refusal points at the repository name" \
  "grep -q 'REQUIRE_CHECKS_REPOSITORY still names this repository' <<< \"\$RC_OUT\""
assert_true "require-checks: a redirect is not reported as a commit whose checks failed" \
  "! grep -q 'no successful' <<< \"\$RC_OUT\""

# The same guard, against an answer that is not JSON at all -- a proxy or a
# gateway error page, which is what a self-hosted runner behind a corporate
# egress actually receives.
printf '<html><body>502 Bad Gateway</body></html>' > "$RC_DIR/rest-html.json"
run_require_checks_curl rest-html.json
assert_true "require-checks: a non-JSON answer is refused rather than parsed as no checks" \
  "[[ $RC_STATUS -eq 1 ]] && ! grep -q 'no successful' <<< \"\$RC_OUT\""

# ...and says WHAT it got. `jq` prints nothing for a body it cannot parse and its
# stderr is suppressed, so reading `.message` alone left the line as `It said:`
# with nothing after it -- on exactly the answer (a proxy's error page) that this
# branch exists to make legible. The raw first line is the fallback.
assert_true "require-checks: a non-JSON refusal quotes the body instead of saying nothing" \
  "grep -q '502 Bad Gateway' <<< \"\$RC_OUT\""
assert_true "require-checks: the refusal never prints an empty 'It said:' line" \
  "! grep -qE 'It said:[[:space:]]*$' <<< \"\$RC_OUT\""

# The gate is allowed to be wrong in ONE direction, and these three say so.
#
# `jq -s` truncates its target before it fails, so a stream it cannot assemble
# leaves the checks file EMPTY -- and an empty file did not make the gate refuse,
# it made the gate PASS: `jq ... | length` prints nothing, the per-name test
# becomes `[ "" -eq 0 ]`, POSIX `sh` answers "Illegal number" with status 2, and
# `if` reads that as false and takes the branch that prints `OK`. Every required
# check reported as passing, on a commit whose check runs were never read.
#
# Stubbed on the `gh` transport rather than `curl`, because that is where it is
# genuinely REACHABLE: the curl path validates the shape of each page before it
# emits anything, so its own output is always well-formed JSONL, while `gh api
# --paginate --jq` is trusted verbatim -- and `gh` is entitled to put a notice on
# stdout. A test that could only be reached through an impossible curl response
# would be asserting against a state the script cannot enter.
printf 'gh: a notice nobody parses\n{"name":"tests > test:all","conclusion":"success"}\n' \
  > "$RC_DIR/unfoldable.json"
run_require_checks unfoldable.json
assert_true "require-checks: a stream that will not fold exits non-zero" "[[ $RC_STATUS -ne 0 ]]"
assert_true "require-checks: a stream that will not fold never reports the gate as passed" \
  "! grep -q 'All required checks passed' <<< \"\$RC_OUT\""
assert_true "require-checks: a stream that will not fold never prints OK for a required name" \
  "! grep -qE '^OK: ' <<< \"\$RC_OUT\""
assert_true "require-checks: the fold failure says the shape was wrong, not that the tests failed" \
  "grep -q 'could not be assembled into an array' <<< \"\$RC_OUT\""

# A page that legitimately carries NO check runs still has to be readable as
# "this commit was never tested", which is the opposite verdict and the one the
# empty-list branch exists for. Guarding the shape must not swallow it.
printf '{"total_count":0,"check_runs":[]}' > "$RC_DIR/rest-untested.json"
run_require_checks_curl rest-untested.json
assert_true "require-checks: an empty but well-formed page is still refused as an untested commit" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q 'no successful .tests > test:all.' <<< \"\$RC_OUT\""
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All deployment provider tests passed!"
