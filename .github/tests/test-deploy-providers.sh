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

WORK_DIR="$(mktemp -d)" || exit 1
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# The few assertions that read a workflow's YAML use Go test support
# (`internal/testsuites/deployproviders`), built from this checkout for this run.
# One that does not build stops the suite here, before any assertion runs, rather
# than leaving those assertions to fail one by one for a reason that has nothing
# to do with the providers. The deployment receipts are JSON, read with `jq`, which
# the require-checks cases below already need.
mkdir -p "$WORK_DIR/tools" || exit 1
DEPLOY_WORKFLOWS="$WORK_DIR/tools/deployproviders"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$DEPLOY_WORKFLOWS" ./internal/testsuites/deployproviders; then
  echo -e "${RED}could not build ./internal/testsuites/deployproviders, so no assertion can run${NC}"
  exit 1
fi

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

# Two values the Fly.io cases repeat: the deploy a build from source records for
# the fixture app, and the condition every "deploys nothing" case asserts. Kept
# as constants so a change to either is made once.
FLY_SOURCE_BUILD='flyctl deploy --remote-only --app my-mvp'
NOTHING_DEPLOYED='[[ -z "$CMD" ]]'

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
    cd "$projectDir" || exit 1
    # Clear every variable this family reads so each case starts from a known
    # state rather than inheriting the previous one's configuration.
    unset VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID VERCEL_WORKING_DIRECTORY \
      VERCEL_COMMERCIAL VERCEL_PLAN \
      CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_TARGET \
      CLOUDFLARE_PROJECT_NAME CLOUDFLARE_OUTPUT_DIRECTORY CLOUDFLARE_BRANCH \
      CLOUDFLARE_PRODUCTION_BRANCH CLOUDFLARE_API_URL \
      NETLIFY_AUTH_TOKEN NETLIFY_SITE_ID NETLIFY_OUTPUT_DIRECTORY NETLIFY_DEPLOY_MESSAGE \
      RENDER_API_KEY RENDER_SERVICE_ID RENDER_SERVICE_NAME RENDER_DEPLOY_HOOK_URL \
      FLY_API_TOKEN FLY_APP_NAME FLY_ORG FLY_MACHINE_COUNT FLY_CONFIG FLY_STRATEGY \
      FLY_VERSION_BUILD_ARG FLY_APP_VERSION \
      FLY_IMAGE FLY_IMAGE_REGISTRY_USERNAME FLY_IMAGE_REGISTRY_PASSWORD \
      DEPLOY_ENVIRONMENT
    # The CI platform's own description of the build, which the Fly version is
    # derived from. Cleared for the same reason: this suite runs INSIDE GitHub
    # Actions, where these are always set, so a case that did not clear them
    # would assert the CI run's own commit rather than its fixture.
    unset GITHUB_REF_TYPE GITHUB_REF_NAME GITHUB_SHA CI_COMMIT_TAG CI_COMMIT_SHA \
      BUILD_SOURCEBRANCH BUILD_SOURCEVERSION
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
  "$FLY_SOURCE_BUILD" "$CMD"
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
  "$FLY_SOURCE_BUILD" "$CMD"
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

# Machine count. Fly adds a SPARE machine the first time it fills a process group, which is
# silently wrong -- not broken -- for a process that is not safe to run twice, so it has to
# be refused rather than noticed.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_MACHINE_COUNT=1
assert_equals "flyio: a single-machine app refuses Fly's spare" \
  "flyctl deploy --remote-only --app my-mvp --ha=false" "$CMD"

# Only for a count of 1: every other value is a deliberate choice to run several, and
# --ha=false there would fight the caller.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_MACHINE_COUNT=3
assert_equals "flyio: a multi-machine app keeps Fly's own HA behaviour" \
  "$FLY_SOURCE_BUILD" "$CMD"

run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp
assert_equals "flyio: an unset count changes the deploy not at all" \
  "$FLY_SOURCE_BUILD" "$CMD"

# A malformed count is refused UP FRONT rather than at either enforcement point, because
# those two fail asymmetrically: `1 ` (trailing space, invisible in a settings UI) is not
# equal to `1`, so `--ha=false` is skipped and Fly creates the spare, and then the deploy
# SUCCEEDS and `flyctl scale count '1 '` is rejected after the release is already live --
# leaving the app on two machines, which is the state this feature exists to prevent.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp "FLY_MACHINE_COUNT=1 "
assert_true "flyio: a whitespace-padded count fails the job" "[[ $STATUS -eq 1 ]]"
assert_true "flyio: the rejection names the offending value" \
  "grep -q 'must be a whole number' <<< \"\$OUT\""
# Nothing may be recorded, because nothing may be attempted -- a count rejected after the
# deploy is the failure this check exists to move earlier.
assert_true "flyio: a rejected count deploys nothing at all" "$NOTHING_DEPLOYED"

run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_MACHINE_COUNT=one
assert_true "flyio: a non-numeric count fails the job" "[[ $STATUS -eq 1 ]]"

# The count is a CEILING enforced after the deploy; fly.toml's min_machines_running is a
# floor and cannot express it. Structural: `scale count` needs a real API.
assert_true "flyio: the count is enforced with scale count, not just hinted at deploy" \
  "grep -q 'flyctl scale count' '$FLYIO_SH'"
# Matches the GUARD, not the token: `EXIT_CODE:-` alone also matches the pre-existing
# final line `exit "${EXIT_CODE:-0}"`, so deleting the whole scale block -- the exact
# regression this assertion is named for -- still left it green. Nothing else here can
# observe the guard: the functional cases above are dry runs, and the scale block is
# deliberately skipped under `deploy_is_dry_run`.
assert_true "flyio: scaling is skipped when the deploy itself failed" \
  "grep -qF -- '-z \"\${EXIT_CODE:-}\"' '$FLYIO_SH'"
assert_true "flyio: the count is exposed as a caller variable name too" \
  "grep -q 'fly_machine_count_var' '$GO_FLYIO'"
assert_true "flyio: Azure forwards FLY_MACHINE_COUNT" \
  "grep -q 'FLY_MACHINE_COUNT' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/flyio.yaml'"
assert_true "flyio: GitLab documents FLY_MACHINE_COUNT" \
  "grep -q 'FLY_MACHINE_COUNT' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/flyio.yaml'"
# A caller-controlled input spliced into a `run:` body is pasted in before bash parses
# it, so `\$(...)` in the value executes in the job holding FLY_API_TOKEN. Every value
# these steps read must arrive through `env:`.
assert_true "flyio: no workflow_call input is interpolated into a run: body" \
  "! awk '/^ *run:/,/^ *(shell|env|with|if|-|jobs):/' '$GO_FLYIO' | grep -q 'inputs\.'"

# The version build argument. `--remote-only` builds from source on Fly's builder, so a
# Dockerfile that compiles its version in (`ARG VERSION=dev`, then `-ldflags -X`) reported
# its default on every deploy: nothing passed the argument. Opting in is NAMING the `ARG`.
SHA='0123456789abcdef0123456789abcdef01234567'

# Off unless named, even with every platform variable present: a build argument this
# script chose on its own would override a project's unrelated `ARG VERSION`.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=1.2.3 GITHUB_SHA="$SHA"
assert_equals "flyio: no build argument is passed unless one is named" \
  "$FLY_SOURCE_BUILD" "$CMD"

run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_SHA="$SHA"
assert_equals "flyio: a branch build passes the commit's first 7 characters" \
  "flyctl deploy --remote-only --app my-mvp --build-arg VERSION=0123456" "$CMD"
assert_no_leak "flyio: the API token is never recorded with a version build argument"

run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=1.2.3 GITHUB_SHA="$SHA"
assert_equals "flyio: a tag build passes the tag" \
  "flyctl deploy --remote-only --app my-mvp --build-arg VERSION=1.2.3" "$CMD"

# The explicit value is how `go-flyio.yaml` hands over the release a bump merge has just
# cut: that deploy runs on the branch, and would otherwise report the commit while the
# image pushed in the same run reports the release.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  FLY_APP_VERSION=2.0.0 GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_SHA="$SHA"
assert_equals "flyio: FLY_APP_VERSION wins over what the platform describes" \
  "flyctl deploy --remote-only --app my-mvp --build-arg VERSION=2.0.0" "$CMD"

# One script on three platforms, so each platform's description of the build is read.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  CI_COMMIT_TAG=3.0.0 CI_COMMIT_SHA="$SHA"
assert_equals "flyio: a GitLab tag pipeline passes the tag" \
  "flyctl deploy --remote-only --app my-mvp --build-arg VERSION=3.0.0" "$CMD"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  CI_COMMIT_SHA="$SHA"
assert_equals "flyio: a GitLab branch pipeline passes the commit" \
  "flyctl deploy --remote-only --app my-mvp --build-arg VERSION=0123456" "$CMD"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  BUILD_SOURCEBRANCH=refs/tags/release/4.0.0 BUILD_SOURCEVERSION="$SHA"
assert_equals "flyio: an Azure DevOps tag build passes the whole tag, not its last segment" \
  "flyctl deploy --remote-only --app my-mvp --build-arg VERSION=release/4.0.0" "$CMD"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  BUILD_SOURCEBRANCH=refs/heads/main BUILD_SOURCEVERSION="$SHA"
assert_equals "flyio: an Azure DevOps branch build passes the commit" \
  "flyctl deploy --remote-only --app my-mvp --build-arg VERSION=0123456" "$CMD"

# A malformed name is refused before anything is deployed, because nothing downstream
# refuses it: a build argument no `ARG` declares is ignored, so `VERSION ` would deploy an
# image still reporting its default, the state opting in exists to end.
for name in 'VERSION ' '9VERSION' 'APP-VERSION'; do
  run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp "FLY_VERSION_BUILD_ARG=$name" \
    GITHUB_SHA="$SHA"
  assert_true "flyio: the build argument name '$name' fails the job" "[[ $STATUS -eq 1 ]]"
  assert_true "flyio: the name '$name' is refused before anything is deployed" "$NOTHING_DEPLOYED"
done
assert_true "flyio: the rejection names what a build argument name may contain" \
  "grep -q 'must name a Dockerfile ARG' <<< \"\$OUT\""

# A newline inside the value would reach a NEWLINE-separated build-args list as a second
# argument, so a value that is not one word is refused rather than passed on.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  "FLY_APP_VERSION=$(printf '1.0\nOTHER=1')"
assert_true "flyio: a version that is not one word fails the job" "[[ $STATUS -eq 1 ]]"
assert_true "flyio: a version that is not one word deploys nothing" "$NOTHING_DEPLOYED"

# Opted in and nothing to resolve: no platform variable and no git checkout. Fails rather
# than deploying the default, since "opted in and got nothing" must never be silent.
# GIT_CEILING_DIRECTORIES keeps `git` from finding a repository ABOVE the throwaway
# project, which would make this case depend on where the suite happens to run.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_VERSION_BUILD_ARG=VERSION \
  GIT_CEILING_DIRECTORIES="$WORK_DIR"
assert_true "flyio: a version that cannot be resolved fails the job" "[[ $STATUS -eq 1 ]]"
assert_true "flyio: an unresolvable version deploys nothing" "$NOTHING_DEPLOYED"
assert_true "flyio: the failure says no version could be resolved" \
  "grep -q 'no version could be resolved' <<< \"\$OUT\""

# A valid name the Dockerfile never declares is the one silent miss left, so it warns. The
# Dockerfile is the one `[build] dockerfile` names, relative to the config's directory, else
# that directory's `Dockerfile`. Both live outside the project directory, which
# `run_provider` wipes before each run.
mkdir -p "$WORK_DIR/fly-version/.ci"
printf 'app = "my-mvp"\n\n[build]\n  dockerfile = ".ci/app.Dockerfile"\n\n[env]\n  PORT = "8080"\n' \
  > "$WORK_DIR/fly-version/fly.toml"
printf 'FROM scratch\nARG VERSION=dev\n' > "$WORK_DIR/fly-version/.ci/app.Dockerfile"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_CONFIG="$WORK_DIR/fly-version/fly.toml" \
  FLY_VERSION_BUILD_ARG=VERSION GITHUB_SHA="$SHA"
assert_true "flyio: a Dockerfile that declares the ARG raises no warning" \
  "! grep -q 'declares no' <<< \"\$OUT\""
printf 'FROM scratch\n' > "$WORK_DIR/fly-version/.ci/app.Dockerfile"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_CONFIG="$WORK_DIR/fly-version/fly.toml" \
  FLY_VERSION_BUILD_ARG=VERSION GITHUB_SHA="$SHA"
assert_true "flyio: a Dockerfile named by [build] that lacks the ARG warns" \
  "grep -q \"declares no 'ARG VERSION'\" <<< \"\$OUT\""
# ...and only warns: the check reads the file line by line, so it must never cost a deploy.
assert_true "flyio: the missing ARG does not stop the deploy" \
  "[[ $STATUS -eq 0 ]] && grep -q -- '--build-arg VERSION=0123456' <<< \"\$CMD\""
printf 'app = "my-mvp"\n' > "$WORK_DIR/fly-version/fly.toml"
printf 'FROM scratch\n' > "$WORK_DIR/fly-version/Dockerfile"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_CONFIG="$WORK_DIR/fly-version/fly.toml" \
  FLY_VERSION_BUILD_ARG=VERSION GITHUB_SHA="$SHA"
assert_true "flyio: with no [build] dockerfile, the config directory's Dockerfile is checked" \
  "grep -q \"fly-version/Dockerfile' declares no 'ARG VERSION'\" <<< \"\$OUT\""

# The wiring contract again: the knob on all three platforms, and through `go-flyio.yaml`
# to every build of the commit -- the registry image, and Fly's own for a caller that
# builds from source.
assert_true "flyio: GitHub action forwards FLY_VERSION_BUILD_ARG and FLY_APP_VERSION" \
  "grep -q 'FLY_VERSION_BUILD_ARG' '$SCRIPTS_DIR/github/global/stages/50-deployment/flyio/action.yaml' && grep -q 'FLY_APP_VERSION' '$SCRIPTS_DIR/github/global/stages/50-deployment/flyio/action.yaml'"
assert_true "flyio: Azure template forwards FLY_VERSION_BUILD_ARG and FLY_APP_VERSION" \
  "grep -q 'FLY_VERSION_BUILD_ARG' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/flyio.yaml' && grep -q 'FLY_APP_VERSION' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/flyio.yaml'"
assert_true "flyio: GitLab template documents FLY_VERSION_BUILD_ARG and FLY_APP_VERSION" \
  "grep -q 'FLY_VERSION_BUILD_ARG' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/flyio.yaml' && grep -q 'FLY_APP_VERSION' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/flyio.yaml'"
echo ""

# ---------------------------------------------------------------------------
echo "7. Functional: Fly.io deploying a delivered image"
# ---------------------------------------------------------------------------
# `go-flyio.yaml` hands the deploy the image `delivery > docker` already pushed,
# and the script copies its linux/amd64 build into registry.fly.io and deploys it
# by digest. Rebuilding the Dockerfile on Fly's builder took most of every deploy
# and shipped an image with another digest than the one CI had pushed -- so every
# assertion here is about one of two things: nothing is built, and nothing but
# that digest can be deployed.
INDEX_DIGEST="sha256:$(printf 'a%.0s' $(seq 64))"
CHILD_HEX="$(printf 'c%.0s' $(seq 64))"
CHILD_DIGEST="sha256:$CHILD_HEX"
DELIVERED="ghcr.io/fixture-owner/fixture-repo@$INDEX_DIGEST"
# What a dry run records where only the registry could answer: the digest.
DRY_IMAGE='registry.fly.io/my-mvp@<linux/amd64-digest>'

run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE="$DELIVERED"
assert_equals "flyio: a delivered image is deployed by digest from the app's own registry" \
  "flyctl deploy --image $DRY_IMAGE --app my-mvp" "$CMD"
assert_true "flyio: a delivered image is not rebuilt on Fly's builder (no --remote-only)" \
  "[[ -n \"\$CMD\" ]] && ! grep -q -- '--remote-only' <<< \"\$CMD\""
assert_true "flyio: a dry run names the copy it would make, linux/amd64 only" \
  "grep -qF 'DRY RUN (no copy performed): crane copy --platform linux/amd64 $DELIVERED registry.fly.io/my-mvp:deployment-' <<< \"\$OUT\""
assert_no_leak "flyio: the API token is never recorded when deploying a delivered image"

# The image was built with its version in it: the delivery job got the same build
# argument. So it is neither passed -- there is no build to pass it to -- nor
# validated, since refusing a value nothing reads would cost a deploy for nothing.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE="$DELIVERED" \
  FLY_VERSION_BUILD_ARG=VERSION GITHUB_SHA="$SHA"
assert_equals "flyio: a delivered image gets no --build-arg, its version is already in it" \
  "flyctl deploy --image $DRY_IMAGE --app my-mvp" "$CMD"
assert_true "flyio: the log says why the version build argument is not passed" \
  "grep -q 'FLY_VERSION_BUILD_ARG is not passed' <<< \"\$OUT\""
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE="$DELIVERED" \
  'FLY_VERSION_BUILD_ARG=VERSION ' GITHUB_SHA="$SHA"
assert_true "flyio: a build argument name nothing reads is not refused" "[[ $STATUS -eq 0 ]]"

# Every other flag means what it meant before.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE="$DELIVERED" \
  FLY_STRATEGY=bluegreen FLY_MACHINE_COUNT=1
assert_equals "flyio: a delivered image keeps the strategy and the single-machine guard" \
  "flyctl deploy --image $DRY_IMAGE --app my-mvp --strategy bluegreen --ha=false" "$CMD"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_CONFIG="$WORK_DIR/fly-from-toml.toml" \
  FLY_IMAGE="$DELIVERED"
assert_equals "flyio: an app named only in fly.toml receives the image, with no --app added" \
  "flyctl deploy --image registry.fly.io/app-from-toml@<linux/amd64-digest> --config $WORK_DIR/fly-from-toml.toml" "$CMD"

# The copy needs the app's name, so a deploy that cannot resolve one stops before
# anything is installed or copied -- on a dry run as well, which needs no network
# to find it out.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_IMAGE="$DELIVERED"
assert_true "flyio: a delivered image with no app name fails the job" "[[ $STATUS -eq 1 ]]"
assert_true "flyio: the failure says the copy needs the app name" \
  "grep -q 'no app name could be resolved, and the image is copied to registry.fly.io/<app>' <<< \"\$OUT\""
assert_true "flyio: an image with no app name deploys nothing" "$NOTHING_DEPLOYED"

run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp "FLY_IMAGE=$DELIVERED "
assert_true "flyio: an image reference holding whitespace fails the job" "[[ $STATUS -eq 1 ]]"
assert_true "flyio: the rejection says what a reference may contain" \
  "grep -q 'FLY_IMAGE must be an image reference' <<< \"\$OUT\""
assert_true "flyio: a malformed reference deploys nothing" "$NOTHING_DEPLOYED"

# No image is today's deploy, byte for byte.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE=
assert_equals "flyio: an empty image keeps the build from source" \
  "$FLY_SOURCE_BUILD" "$CMD"

# The receipt names what shipped and what it was copied from: that pair is the
# evidence the pipeline's own artifact went out.
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE="$DELIVERED"
assert_equals "flyio: the receipt records the image the deploy ships" "$DRY_IMAGE" \
  "$(jq -r '.image' "$REPORT_DIR/deployment.json" 2>&1)"
assert_equals "flyio: the receipt records the delivered image it came from" "$DELIVERED" \
  "$(jq -r '.source_image' "$REPORT_DIR/deployment.json" 2>&1)"
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp
assert_true "flyio: a build from source writes the receipt it always wrote, with no image" \
  "! grep -q 'image' '$REPORT_DIR/deployment.json'"

# A dry run installs nothing and copies nothing. Proven with a PATH holding only
# the tools the script needs and RECORDING stand-ins for every way to reach the
# network, so "installed nothing" is observed rather than inferred from a log line
# -- and with a scratch HOME, since `$HOME/.local/bin` is where an install lands.
FLY_MINIMAL_BIN="$WORK_DIR/fly-minimal-bin"
FLY_NET_BIN="$WORK_DIR/fly-network-bin"
FLY_STUB_BIN="$WORK_DIR/fly-stub-bin"
FLY_STUB_DIR="$WORK_DIR/fly-stub-records"
mkdir -p "$FLY_MINIMAL_BIN" "$FLY_NET_BIN" "$FLY_STUB_BIN" "$FLY_STUB_DIR"
for tool in sh env rm mkdir cat tr sed head dirname realpath uname mktemp awk grep; do
  toolPath="$(type -P "$tool" || true)"
  if [[ -n "$toolPath" ]]; then ln -sf "$toolPath" "$FLY_MINIMAL_BIN/$tool"; fi
done
for tool in curl wget; do
  cat > "$FLY_NET_BIN/$tool" <<STUB
#!/bin/sh
echo "$tool \$*" >> "\$FLY_STUB_DIR/network"
exit 1
STUB
  chmod +x "$FLY_NET_BIN/$tool"
done

# crane and flyctl stand-ins. Each records its argv, which is what the "no secret
# on argv" assertions read; crane also records the DOCKER_CONFIG it was handed and
# what a login receives on stdin, and flyctl records whether the source registry's
# password reached its environment. A login writes a `config.json` where the real
# `crane auth login` does -- DOCKER_CONFIG, else `$HOME/.docker` -- so where the
# credentials land is observed, not assumed. `crane digest` answers the
# linux/amd64 manifest's digest under the reference's repository, as the real one
# does with `--full-ref`, and FLY_STUB_FAIL names a subcommand that fails.
cat > "$FLY_STUB_BIN/crane" <<'STUB'
#!/bin/sh
printf 'crane' >> "$FLY_STUB_DIR/argv"
for argument in "$@"; do printf ' %s' "$argument" >> "$FLY_STUB_DIR/argv"; done
printf '\n' >> "$FLY_STUB_DIR/argv"
printf '%s\n' "${DOCKER_CONFIG:-<unset>}" >> "$FLY_STUB_DIR/docker-config"
if [ "$1" = "${FLY_STUB_FAIL:-}" ]; then exit 1; fi
case "$1 $2" in
  'auth login')
    cat > "$FLY_STUB_DIR/stdin-$3"
    mkdir -p "${DOCKER_CONFIG:-$HOME/.docker}"
    printf '{"auths":{"%s":{}}}\n' "$3" > "${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    ;;
  'digest --platform') printf '%s@%s\n' "${5%@*}" "$FLY_STUB_CHILD_DIGEST" ;;
esac
exit 0
STUB
cat > "$FLY_STUB_BIN/flyctl" <<'STUB'
#!/bin/sh
printf 'flyctl' >> "$FLY_STUB_DIR/argv"
for argument in "$@"; do printf ' %s' "$argument" >> "$FLY_STUB_DIR/argv"; done
printf '\n' >> "$FLY_STUB_DIR/argv"
printf '%s\n' "${FLY_IMAGE_REGISTRY_PASSWORD-<unset>}" >> "$FLY_STUB_DIR/flyctl-env"
# Whether the registry credentials crane was handed are still in reach: named in
# this process's environment, or still on disk where crane found them.
credentials="$(head -n 1 "$FLY_STUB_DIR/docker-config")"
if [ -n "${DOCKER_CONFIG:-}" ] || { [ -n "$credentials" ] && [ -e "$credentials" ]; }; then
  echo 'in reach' >> "$FLY_STUB_DIR/flyctl-credentials"
else
  echo 'gone' >> "$FLY_STUB_DIR/flyctl-credentials"
fi
if [ "$1" = "${FLY_STUB_FAIL:-}" ]; then exit 1; fi
exit 0
STUB
chmod +x "$FLY_STUB_BIN/crane" "$FLY_STUB_BIN/flyctl"

# run_flyio_isolated <path> [VAR=value...]
#
# Runs the Fly.io script under `env -i` with exactly <path> on PATH and a scratch
# HOME, leaving the same $STATUS/$OUT/$CMD/$REPORT_DIR as `run_provider` plus the
# stand-ins' records. NOT a dry run unless a case asks for one: these cases drive
# the real copy and deploy against the stand-ins above.
run_flyio_isolated() {
  local path="$1"
  shift
  local project_dir="$WORK_DIR/isolated-project"
  local home_dir="$WORK_DIR/isolated-home"
  rm -rf "$project_dir" "$home_dir" "$FLY_STUB_DIR"
  mkdir -p "$project_dir" "$home_dir" "$FLY_STUB_DIR"
  : > "$FLY_STUB_DIR/argv"
  : > "$FLY_STUB_DIR/network"
  : > "$FLY_STUB_DIR/docker-config"
  : > "$FLY_STUB_DIR/flyctl-env"
  : > "$FLY_STUB_DIR/flyctl-credentials"

  STATUS=0
  (
    cd "$project_dir" || exit 1
    env -i PATH="$path" HOME="$home_dir" SCRIPTS_DIR="$SCRIPTS_DIR" \
      FLY_STUB_DIR="$FLY_STUB_DIR" FLY_STUB_CHILD_DIGEST="$CHILD_DIGEST" "$@" \
      "$FLY_MINIMAL_BIN/sh" "$FLYIO_SH"
  ) > "$project_dir/out.txt" 2>&1 || STATUS=$?

  REPORT_DIR="$project_dir/build/reports/deploy-flyio"
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions, which ShellCheck cannot see
  OUT="$(cat "$project_dir/out.txt")"
  CMD=""
  if [[ -f "$REPORT_DIR/command.txt" ]]; then CMD="$(cat "$REPORT_DIR/command.txt")"; fi
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions
  STUB_ARGV="$(cat "$FLY_STUB_DIR/argv")"
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions
  STUB_NETWORK="$(cat "$FLY_STUB_DIR/network")"
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions
  ISOLATED_HOME="$home_dir"
}

run_flyio_isolated "$FLY_NET_BIN:$FLY_MINIMAL_BIN" DEPLOY_DRY_RUN=true \
  FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE="$DELIVERED"
assert_true "flyio: a dry run of a delivered image exits cleanly with no CLI on PATH" "[[ $STATUS -eq 0 ]]"
assert_true "flyio: a dry run skips installing crane, and says so" \
  "grep -q 'DRY RUN: skipping installation of crane.' <<< \"\$OUT\""
assert_true "flyio: a dry run downloads nothing" "[[ -z \"\$STUB_NETWORK\" ]]"
assert_true "flyio: a dry run leaves no crane behind in HOME" "[[ ! -e '$WORK_DIR/isolated-home/.local/bin/crane' ]]"

run_flyio_isolated "$FLY_STUB_BIN:$FLY_NET_BIN:$FLY_MINIMAL_BIN" DEPLOY_DRY_RUN=true \
  FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp FLY_IMAGE="$DELIVERED" \
  FLY_IMAGE_REGISTRY_USERNAME=fixture-actor FLY_IMAGE_REGISTRY_PASSWORD="$SENTINEL"
assert_true "flyio: a dry run with crane available still runs neither crane nor flyctl" \
  "[[ $STATUS -eq 0 && -z \"\$STUB_ARGV\" ]]"
assert_no_leak "flyio: a dry run never records the source registry's password"

# The REAL path, against the stand-ins. Guarded first: these cases run the script
# without DEPLOY_DRY_RUN, so they must provably reach the stand-ins and nothing
# else -- the workstation running this suite may hold a logged-in flyctl.
STUB_RESOLVES="$(env -i PATH="$FLY_STUB_BIN:$FLY_NET_BIN:$FLY_MINIMAL_BIN" \
  "$FLY_MINIMAL_BIN/sh" -c 'command -v flyctl; command -v crane' 2>&1 || true)"
if [[ "$STUB_RESOLVES" == "$FLY_STUB_BIN/flyctl"$'\n'"$FLY_STUB_BIN/crane" ]]; then
  STUB_PATH="$FLY_STUB_BIN:$FLY_NET_BIN:$FLY_MINIMAL_BIN"
  FLY_TOKEN_FIXTURE="FlyV1 fm2_$SENTINEL,fm2_fixture-second"

  run_flyio_isolated "$STUB_PATH" FLY_API_TOKEN="$FLY_TOKEN_FIXTURE" FLY_APP_NAME=my-mvp \
    FLY_IMAGE="$DELIVERED" FLY_IMAGE_REGISTRY_USERNAME=fixture-actor \
    FLY_IMAGE_REGISTRY_PASSWORD="$SENTINEL-registry" FLY_VERSION_BUILD_ARG=VERSION GITHUB_SHA="$SHA"
  assert_true "flyio: a delivered image deploys" "[[ $STATUS -eq 0 ]]"
  # One assertion over the whole sequence, so it holds the order as well as each
  # line: both logins before any read, the copy reading the digest it resolved
  # into a tag named after that digest, and the deploy shipping that digest --
  # with neither --remote-only nor --build-arg, although a build argument is named.
  assert_equals "flyio: the image is resolved, copied and deployed by one digest, in that order" \
    "$(printf '%s\n' \
      'crane auth login ghcr.io --username fixture-actor --password-stdin' \
      'crane auth login registry.fly.io --username x --password-stdin' \
      "crane digest --platform linux/amd64 --full-ref $DELIVERED" \
      "crane copy --platform linux/amd64 ghcr.io/fixture-owner/fixture-repo@$CHILD_DIGEST registry.fly.io/my-mvp:deployment-$CHILD_HEX" \
      "flyctl deploy --image registry.fly.io/my-mvp@$CHILD_DIGEST --app my-mvp")" \
    "$STUB_ARGV"
  assert_equals "flyio: command.txt holds the deploy of that digest" \
    "flyctl deploy --image registry.fly.io/my-mvp@$CHILD_DIGEST --app my-mvp" "$CMD"
  assert_equals "flyio: the receipt names the digest deployed" "registry.fly.io/my-mvp@$CHILD_DIGEST" \
    "$(jq -r '.image' "$REPORT_DIR/deployment.json" 2>&1)"
  assert_equals "flyio: the receipt names the delivered build it was copied from" \
    "ghcr.io/fixture-owner/fixture-repo@$CHILD_DIGEST" \
    "$(jq -r '.source_image' "$REPORT_DIR/deployment.json" 2>&1)"

  # Both credentials reach crane on stdin -- never on argv -- and the Fly token as
  # flyctl hands it to the registry itself: without its `FlyV1 ` scheme.
  assert_true "flyio: no credential is on any argv the copy or the deploy ran with" \
    "! grep -q '$SENTINEL' <<< \"\$STUB_ARGV\""
  assert_equals "flyio: the source registry's password arrives on stdin" "$SENTINEL-registry" \
    "$(cat "$FLY_STUB_DIR/stdin-ghcr.io" 2>&1)"
  assert_equals "flyio: registry.fly.io gets the token without its FlyV1 scheme, on stdin" \
    "fm2_$SENTINEL,fm2_fixture-second" "$(cat "$FLY_STUB_DIR/stdin-registry.fly.io" 2>&1)"
  assert_no_leak "flyio: no credential reaches the report of a real image deploy"
  assert_true "flyio: flyctl does not inherit the source registry's password" \
    "[[ -s '$FLY_STUB_DIR/flyctl-env' ]] && ! grep -qv '^<unset>\$' '$FLY_STUB_DIR/flyctl-env'"

  # The credentials live in a throwaway DOCKER_CONFIG, never in $HOME/.docker,
  # which a persistent self-hosted runner keeps for the next job -- and it is gone
  # once the job is.
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions
  STUB_DOCKER_CONFIG="$(sort -u "$FLY_STUB_DIR/docker-config")"
  assert_true "flyio: every crane call shares one DOCKER_CONFIG" \
    "[[ \$(grep -c . <<< \"\$STUB_DOCKER_CONFIG\") -eq 1 && \"\$STUB_DOCKER_CONFIG\" != '<unset>' ]]"
  assert_true "flyio: that DOCKER_CONFIG is not under HOME" \
    "[[ \"\$STUB_DOCKER_CONFIG\" != \"\$ISOLATED_HOME\"* ]]"
  assert_true "flyio: that DOCKER_CONFIG is removed when the job ends" "[[ ! -e \"\$STUB_DOCKER_CONFIG\" ]]"
  # ...and before flyctl runs: flyctl needs neither credential, so it should find
  # no DOCKER_CONFIG in its environment and no credentials left on disk.
  assert_true "flyio: flyctl runs after the registry credentials are gone" \
    "[[ -s '$FLY_STUB_DIR/flyctl-credentials' ]] && ! grep -qv '^gone\$' '$FLY_STUB_DIR/flyctl-credentials'"
  assert_true "flyio: nothing was written to HOME/.docker" "[[ ! -e \"\$ISOLATED_HOME/.docker\" ]]"
  assert_true "flyio: a real image deploy downloads nothing when both CLIs are present" \
    "[[ -z \"\$STUB_NETWORK\" ]]"

  # Nothing is deployed when the image cannot be read or copied, and the
  # credentials are cleaned up on that path too.
  for failing in digest copy; do
    run_flyio_isolated "$STUB_PATH" FLY_API_TOKEN="$FLY_TOKEN_FIXTURE" FLY_APP_NAME=my-mvp \
      FLY_IMAGE="$DELIVERED" FLY_IMAGE_REGISTRY_USERNAME=fixture-actor \
      FLY_IMAGE_REGISTRY_PASSWORD="$SENTINEL-registry" FLY_STUB_FAIL="$failing"
    assert_true "flyio: a failed crane $failing fails the job" "[[ $STATUS -eq 1 ]]"
    assert_true "flyio: a failed crane $failing deploys nothing" \
      "! grep -q '^flyctl deploy' <<< \"\$STUB_ARGV\" && $NOTHING_DEPLOYED"
    assert_true "flyio: a failed crane $failing says nothing was deployed" \
      "grep -q 'Nothing has been deployed' <<< \"\$OUT\""
    # shellcheck disable=SC2034  # read by assert_true's eval'd conditions
    STUB_DOCKER_CONFIG="$(sort -u "$FLY_STUB_DIR/docker-config")"
    assert_true "flyio: a failed crane $failing still removes the credentials" \
      "[[ -n \"\$STUB_DOCKER_CONFIG\" && ! -e \"\$STUB_DOCKER_CONFIG\" ]]"
  done

  # A public image needs no login of its own; registry.fly.io always does.
  run_flyio_isolated "$STUB_PATH" FLY_API_TOKEN="$FLY_TOKEN_FIXTURE" FLY_APP_NAME=my-mvp \
    FLY_IMAGE="$DELIVERED"
  assert_true "flyio: an image with no registry password is read without logging in" \
    "[[ $STATUS -eq 0 ]] && ! grep -q 'auth login ghcr.io' <<< \"\$STUB_ARGV\" && grep -q 'auth login registry.fly.io' <<< \"\$STUB_ARGV\""

  run_flyio_isolated "$STUB_PATH" FLY_API_TOKEN="$FLY_TOKEN_FIXTURE" FLY_APP_NAME=my-mvp \
    FLY_IMAGE="$DELIVERED" FLY_IMAGE_REGISTRY_PASSWORD="$SENTINEL-registry"
  assert_true "flyio: a registry password without a user fails before anything is read" \
    "[[ $STATUS -eq 1 ]] && ! grep -q 'crane digest' <<< \"\$STUB_ARGV\""

  # With no image, the build from source is what runs, and crane is never touched.
  run_flyio_isolated "$STUB_PATH" FLY_API_TOKEN="$FLY_TOKEN_FIXTURE" FLY_APP_NAME=my-mvp \
    FLY_IMAGE_REGISTRY_USERNAME=fixture-actor FLY_IMAGE_REGISTRY_PASSWORD="$SENTINEL-registry"
  assert_equals "flyio: with no image the real deploy builds from source and runs no crane" \
    "$FLY_SOURCE_BUILD" "$STUB_ARGV"
else
  echo -e "${RED}  FAIL: the stand-in flyctl and crane are not what PATH resolves, so the real-path cases did not run${NC}"
  echo -e "${RED}        resolved: $STUB_RESOLVES${NC}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# The wiring contract for the new knobs: on all three platforms, and through
# `go-flyio.yaml` from the delivery job's output.
FLYIO_ACTION="$SCRIPTS_DIR/github/global/stages/50-deployment/flyio/action.yaml"
assert_true "flyio: GitHub action forwards FLY_IMAGE and its registry credentials" \
  "grep -q 'FLY_IMAGE: \"\${{ inputs.image }}\"' '$FLYIO_ACTION' && grep -q 'FLY_IMAGE_REGISTRY_USERNAME: \"\${{ inputs.image_registry_username }}\"' '$FLYIO_ACTION'"
# The job token reaches the script only when there is an image to read with it.
assert_true "flyio: GitHub action maps the registry password only when an image is set" \
  "grep -qF \"FLY_IMAGE_REGISTRY_PASSWORD: \\\"\\\${{ inputs.image != '' && inputs.image_registry_password || '' }}\\\"\" '$FLYIO_ACTION'"
assert_true "flyio: GitHub action defaults the registry credentials to the actor and the job token" \
  "grep -qF \"default: '\\\${{ github.actor }}'\" '$FLYIO_ACTION' && grep -qF \"default: '\\\${{ github.token }}'\" '$FLYIO_ACTION'"
assert_true "flyio: Azure template forwards FLY_IMAGE and its registry credentials" \
  "grep -q 'FLY_IMAGE: \${{ parameters.IMAGE }}' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/flyio.yaml' && grep -q 'FLY_IMAGE_REGISTRY_USERNAME:' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/flyio.yaml' && grep -q 'FLY_IMAGE_REGISTRY_PASSWORD:' '$SCRIPTS_DIR/azure-devops/global/stages/50-deployment/flyio.yaml'"
assert_true "flyio: GitLab template documents FLY_IMAGE and its registry credentials" \
  "grep -q 'FLY_IMAGE --' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/flyio.yaml' && grep -q 'FLY_IMAGE_REGISTRY_USERNAME' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/flyio.yaml' && grep -q 'FLY_IMAGE_REGISTRY_PASSWORD' '$SCRIPTS_DIR/gitlab/global/stages/50-deployment/flyio.yaml'"

# `go-flyio.yaml` deploys the delivered image unless the caller opts out (the
# image's path from the delivery job to this deploy is held by
# `make test ONLY=build-version`), and a run with no image to deploy fails rather than
# quietly building one: falling back to Fly's builder would ship an image this run
# never pushed.
assert_true "flyio: the reusable workflow declares the fly_build_from_source opt-out, off by default" \
  "'$DEPLOY_WORKFLOWS' input-off '$GO_FLYIO' fly_build_from_source"
assert_true "flyio: the reusable workflow refuses a run with no delivered image to deploy" \
  "grep -qF \"if: \\\"!inputs.fly_build_from_source && needs.go-docker.outputs.image == ''\\\"\" '$GO_FLYIO'"
echo ""

# ---------------------------------------------------------------------------
echo "8. Deployment record"
# ---------------------------------------------------------------------------
run_provider flyio FLY_API_TOKEN="$SENTINEL" FLY_APP_NAME=my-mvp
assert_true "record: a deployment.json receipt is written" "[[ -f '$REPORT_DIR/deployment.json' ]]"
assert_true "record: the receipt names the provider" \
  "grep -q '\"provider\": \"flyio\"' '$REPORT_DIR/deployment.json'"
assert_true "record: the receipt marks a dry run as such" \
  "grep -q '\"dry_run\": true' '$REPORT_DIR/deployment.json'"
assert_true "record: the receipt is valid JSON" \
  "jq -e -s 'length == 1' '$REPORT_DIR/deployment.json' > /dev/null"
echo ""

# ---------------------------------------------------------------------------
echo "9. Hermetic dry run"
# ---------------------------------------------------------------------------
# A dry run must not install a CLI: the suite has to work offline, on an agent
# with no Node.js toolchain, without downloading ~100 MB per provider.
run_provider vercel VERCEL_TOKEN="$SENTINEL" VERCEL_ORG_ID=team_1 VERCEL_PROJECT_ID=prj_1
assert_true "dry run: no CLI is installed" "grep -q 'skipping installation' <<< \"\$OUT\""
assert_true "dry run: the log states that nothing was deployed" \
  "grep -q 'no deploy performed' <<< \"\$OUT\""
echo ""

# ---------------------------------------------------------------------------
echo "10. Transport pinning"
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
echo "11. Azure DevOps boolean stringification"
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
  "jq -e -s 'length == 1' '$REPORT_DIR/deployment.json' > /dev/null"
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
  "jq -e -s 'length == 1' '$RECORD_PROBE_DIR/deployment.json' > /dev/null"
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
echo "12. Functional: require-checks"
# ---------------------------------------------------------------------------
# The gate reads the GitHub API, so `gh` is stubbed with a fixture rather than
# the script being trusted to describe itself. What is asserted is the verdict
# it reaches from a given set of check runs, which is the only thing a caller
# depends on.
REQUIRE_SH="$SCRIPTS_DIR/global/scripts/deploy/require-checks/run.sh"
RC_DIR="$WORK_DIR/require-checks"
# The one required name most cases here pass on their own.
RC_REQUIRED='tests > test:all'
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
    cd "$RC_DIR" || exit 1
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
  cd "$RC_DIR" || exit 1
  REQUIRE_CHECKS_NAMES="$RC_REQUIRED" REQUIRE_CHECKS_COMMIT=abc \
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
  cd "$RC_DIR" || exit 1
  env -i PATH="$RC_BIN" HOME="$RC_DIR" \
    REQUIRE_CHECKS_NAMES="$RC_REQUIRED" REQUIRE_CHECKS_COMMIT=abc \
    REQUIRE_CHECKS_REPOSITORY=o/r DEPLOY_DRY_RUN=true SCRIPTS_DIR="$SCRIPTS_DIR" \
    "$RC_BIN/sh" "$REQUIRE_SH"
) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
RC_OUT="$(cat "$RC_DIR/out.txt")"
assert_true "require-checks: a dry run needs neither gh nor jq on PATH" "[[ $RC_STATUS -eq 0 ]]"

# The check must still exist, just later: a real run without the binaries has to
# say so rather than fail somewhere further down with a confusing error.
RC_STATUS=0
(
  cd "$RC_DIR" || exit 1
  env -i PATH="$RC_BIN" HOME="$RC_DIR" \
    REQUIRE_CHECKS_NAMES="$RC_REQUIRED" REQUIRE_CHECKS_COMMIT=abc \
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
  cd "$RC_DIR" || exit 1
  env -i PATH="$RC_NOTRANSPORT_BIN" HOME="$RC_DIR" \
    REQUIRE_CHECKS_NAMES="$RC_REQUIRED" REQUIRE_CHECKS_COMMIT=abc \
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
    cd "$RC_DIR" || exit 1
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
  cd "$RC_DIR" || exit 1
  env -i PATH="$RC_CURL_BIN" HOME="$RC_DIR" \
    CURL_STUB_FIXTURE="$RC_DIR/rest-green.json" \
    REQUIRE_CHECKS_NAMES="$RC_REQUIRED" \
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

# A check run that has not been FINISHED is not a passed one, on the check-run
# path. That is the right verdict when nothing else is known -- and the wrong
# one in the case that motivated the branch path below: during a GitHub Actions
# incident a finished job's check run read `in_progress` for almost an hour
# while the job waiting on it had already started.
printf '{"name":"default / go / tests > test:all","conclusion":null}\n{"name":"code-check > style:golangci-lint","conclusion":"success"}\n' \
  > "$RC_DIR/pending.json"
run_require_checks pending.json
assert_true "require-checks: a pending required check is refused when check runs decide" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q 'pending' <<< \"\$RC_OUT\" && grep -q 'no successful .tests > test:all.' <<< \"\$RC_OUT\""

# THE BRANCH PATH. Given the deployment job's `toJSON(needs)` on a branch run
# verifying its own commit, the gate decides from those jobs and reads no check
# runs. Run as the deployment job would be: GITHUB_* describes the run, and the
# ref type arrives as GITHUB_REF_TYPE, which is all the composite action passes.
# $1 is the PATH: the jq-only one has neither `gh` nor `curl`, so a branch run
# that passes on it has provably read no check run, and the gh-stub one answers
# $5 for the runs that must still read them.
RC_GH_BIN="$RC_DIR/gh-stub-bin"
mkdir -p "$RC_GH_BIN"
for tool in sh dirname realpath sed rm mkdir tr cat env jq; do
  for dir in /bin /usr/bin; do
    if [[ -x "$dir/$tool" ]]; then ln -sf "$dir/$tool" "$RC_GH_BIN/$tool"; break; fi
  done
done
cp "$RC_DIR/stub/gh" "$RC_GH_BIN/gh"

run_require_checks_job() {
  local bin="$1" ref_type="$2" needs="$3" run_sha="${4:-abc}" fixture="${5:-green.json}"
  RC_STATUS=0
  (
    cd "$RC_DIR" || exit 1
    env -i PATH="$bin" HOME="$RC_DIR" GH_STUB_FIXTURE="$RC_DIR/$fixture" \
      REQUIRE_CHECKS_NAMES="$RC_REQUIRED" REQUIRE_CHECKS_COMMIT=abc \
      REQUIRE_CHECKS_REPOSITORY=o/r REQUIRE_CHECKS_NEEDS="$needs" \
      GITHUB_REF_TYPE="$ref_type" GITHUB_SHA="$run_sha" GITHUB_REPOSITORY=o/r \
      SCRIPTS_DIR="$SCRIPTS_DIR" "$bin/sh" "$REQUIRE_SH"
  ) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
  RC_OUT="$(cat "$RC_DIR/out.txt")"
}

NEEDS_GREEN='{"go-docker":{"result":"success","outputs":{"tag_name":"fixture-output-sentinel"}}}'
run_require_checks_job "$RC_NOTRANSPORT_BIN" branch "$NEEDS_GREEN"
assert_true "require-checks: a branch run whose needs all succeeded passes with no API client on PATH" \
  "[[ $RC_STATUS -eq 0 ]]"
assert_true "require-checks: the branch verdict names each job it trusted" \
  "grep -q \"OK: 'go-docker' finished 'success'\" <<< \"\$RC_OUT\""
assert_true "require-checks: a branch run reads no check runs" \
  "! grep -q 'Reading check runs' <<< \"\$RC_OUT\""
# The report directory is published as an artifact, so it keeps the verdict and
# none of the jobs' outputs.
assert_true "require-checks: the branch report records each job's result" \
  "grep -q '\"result\": \"success\"' '$RC_DIR/build/reports/require-checks/needs.json'"
assert_true "require-checks: the branch report leaves the jobs' outputs out" \
  "! grep -q 'fixture-output-sentinel' '$RC_DIR/build/reports/require-checks/needs.json'"

# `success` is the only value that passes. A reusable workflow reports
# `cancelled` when one of its jobs was cancelled -- a CodeQL extractor killed for
# memory is reported that way -- and the deployment's own `if:` only refuses a
# `failure`, so the gate is what stops a deploy whose checks were cut short.
run_require_checks_job "$RC_NOTRANSPORT_BIN" branch '{"go-docker":{"result":"cancelled","outputs":{}}}'
assert_true "require-checks: a branch run with a cancelled dependency is refused, naming it" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q \"'go-docker' finished 'cancelled'\" <<< \"\$RC_OUT\""
assert_true "require-checks: a refused branch run never reports the jobs as passed" \
  "! grep -q 'Every job this deployment needs finished' <<< \"\$RC_OUT\""

run_require_checks_job "$RC_NOTRANSPORT_BIN" branch '{"go-docker":{"result":"skipped","outputs":{}}}'
assert_true "require-checks: a skipped dependency proves nothing and is refused" \
  "[[ $RC_STATUS -eq 1 ]]"

run_require_checks_job "$RC_NOTRANSPORT_BIN" branch \
  '{"build":{"result":"success","outputs":{}},"scan":{"result":"failure","outputs":{}}}'
assert_true "require-checks: one failed dependency among passing ones is refused, naming it" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q \"'scan' finished 'failure'\" <<< \"\$RC_OUT\""

# THE TAG STAYS ON CHECK RUNS, and this is the assertion the branch path must
# never weaken. On a tag the checks are skipped while the delivery job still
# runs, so the workflow holding them reports `success` -- exactly what the gate
# exists to see through. A pending check therefore still refuses a tag, however
# green its needs look.
run_require_checks_job "$RC_GH_BIN" tag "$NEEDS_GREEN" abc pending.json
assert_true "require-checks: a tag run ignores needs and refuses a pending check" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q 'no successful .tests > test:all.' <<< \"\$RC_OUT\""
assert_true "require-checks: a tag run says why it reads check runs" \
  "grep -q \"'tag' run, not a branch run\" <<< \"\$RC_OUT\""

# This run's jobs say nothing about another commit, nor does an unknown ref
# type say that this is a branch: both read check runs.
run_require_checks_job "$RC_GH_BIN" branch "$NEEDS_GREEN" def pending.json
assert_true "require-checks: a branch run verifying another commit reads check runs" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q \"not this run's own commit\" <<< \"\$RC_OUT\""
run_require_checks_job "$RC_GH_BIN" '' "$NEEDS_GREEN" abc pending.json
assert_true "require-checks: an unknown ref type reads check runs" \
  "[[ $RC_STATUS -eq 1 ]] && grep -q 'no successful .tests > test:all.' <<< \"\$RC_OUT\""

# Without needs, a branch run keeps today's behaviour: check runs decide.
run_require_checks_job "$RC_GH_BIN" branch '' abc green.json
assert_true "require-checks: a branch run given no needs still reads check runs" \
  "[[ $RC_STATUS -eq 0 ]] && grep -q \"through 'gh'\" <<< \"\$RC_OUT\""

# A value that is not a needs context is a WIRING error and must read as one,
# never as a red commit -- and an empty one would make "every dependency
# succeeded" vacuously true.
for bad_needs in '{}' '"success"' 'success' '[]'; do
  run_require_checks_job "$RC_NOTRANSPORT_BIN" branch "$bad_needs"
  assert_true "require-checks: needs of $bad_needs is refused as a wiring error" \
    "[[ $RC_STATUS -eq 1 ]] && grep -q 'is not the needs context' <<< \"\$RC_OUT\" && ! grep -q 'no successful' <<< \"\$RC_OUT\""
done

# The dry run stays hermetic on the branch path too: no jq, no client.
RC_STATUS=0
(
  cd "$RC_DIR" || exit 1
  env -i PATH="$RC_BIN" HOME="$RC_DIR" DEPLOY_DRY_RUN=true \
    REQUIRE_CHECKS_NAMES="$RC_REQUIRED" REQUIRE_CHECKS_COMMIT=abc \
    REQUIRE_CHECKS_REPOSITORY=o/r REQUIRE_CHECKS_NEEDS="$NEEDS_GREEN" \
    GITHUB_REF_TYPE=branch GITHUB_SHA=abc GITHUB_REPOSITORY=o/r \
    SCRIPTS_DIR="$SCRIPTS_DIR" "$RC_BIN/sh" "$REQUIRE_SH"
) > "$RC_DIR/out.txt" 2>&1 || RC_STATUS=$?
# Read back only inside `assert_true`'s eval'd string, as with the missing-token
# case above, so ShellCheck cannot see the use.
# shellcheck disable=SC2034
RC_OUT="$(cat "$RC_DIR/out.txt")"
assert_true "require-checks: a branch dry run says it reads no check runs, with no jq on PATH" \
  "[[ $RC_STATUS -eq 0 ]] && grep -q 'reading no check runs' <<< \"\$RC_OUT\""

# THE WIRING, DISCOVERED rather than listed, for the reason the build_env_secrets
# section below gives: a deployment workflow added later is guarded only if it is
# iterated. Every step that runs the gate must hand it the job's own needs, or
# that workflow's branch deploys go back to depending on the check-run record.
RC_WIRING="$("$DEPLOY_WORKFLOWS" require-checks-needs "$SCRIPTS_DIR"/.github/workflows/*.yaml)"
# An empty discovery would otherwise pass every assertion below by running none.
assert_true "require-checks: the wiring discovery found at least one deployment workflow" \
  "grep -q '\.yaml' <<< \"\$RC_WIRING\""
while IFS=$'\t' read -r wiring_file wiring_needs; do
  [[ "$wiring_file" == *.yaml ]] || continue
  assert_equals "require-checks: $wiring_file hands the gate its job's needs" \
    "\${{ toJSON(needs) }}" "$wiring_needs"
done <<< "$RC_WIRING"
echo ""

# =============================================================================
# build_env_secrets -- every VALUE is masked, not just the blob
# =============================================================================
echo "Testing build_env_secrets value masking..."

# THIRD CLASS OF ASSERTION (SECURITY), and the same rule as the argv cases above
# read from the other end: a credential must not reach the LOG either. It did.
# `build_env_secrets` arrives as one multi-line secret, so the runner is taught
# to redact that blob and its `KEY=VALUE` lines -- never the VALUE alone. Every
# later step that renders its own `env:` block prints `KEY: VALUE`, which no
# registered mask matches. medhub-life/frontend-dart runs 34305118198 and
# 34308128013 show `BUILD_ENV_SECRETS: ***` and, in the same env block, a Sentry
# auth token in full.
#
# The step is EXTRACTED FROM THE WORKFLOW AND EXECUTED rather than grepped for
# the shape of its loop. A second copy of that loop living here would keep
# passing after the workflow's own copy was edited, and this is a failure nobody
# sees until the credential is already in a retained log.
MASK_DIR="$WORK_DIR/build-env-secrets"
mkdir -p "$MASK_DIR"

# Parsed rather than read as indented text, for the reason the azure-step-names
# suite states: the body is a block scalar, and re-deriving its indentation by
# hand is a parser. A workflow with no such step prints a sentence instead of a
# script, so the assertions below fail by name rather than pass against nothing.
extract_secrets_step() {
  "$DEPLOY_WORKFLOWS" secrets-step "$1"
}

# Runs the real step against $2, leaving its stdout in MASK_OUT and the file it
# appended to in MASK_ENV. Both are CLEARED first: a run that cannot produce
# output must fail its assertions by name rather than pass them against whatever
# the previous workflow in the loop left behind.
run_secrets_step() {
  local workflow="$1"
  local payload="$2"
  MASK_STATUS=0
  # Read by `eval` inside assert_true, which shellcheck cannot follow. The RC_*
  # pair above escapes the same warning only because it is also assigned at top
  # level; being honest about it costs one directive.
  # shellcheck disable=SC2034
  MASK_OUT=""
  # shellcheck disable=SC2034
  MASK_ENV=""
  : > "$MASK_DIR/github_env"
  extract_secrets_step "$workflow" > "$MASK_DIR/step.sh"
  (
    cd "$MASK_DIR" || exit 1
    BUILD_ENV_SECRETS="$payload" GITHUB_ENV="$MASK_DIR/github_env" \
      bash "$MASK_DIR/step.sh"
  ) > "$MASK_DIR/out.txt" 2>&1 || MASK_STATUS=$?
  # shellcheck disable=SC2034
  MASK_OUT="$(cat "$MASK_DIR/out.txt")"
  # shellcheck disable=SC2034
  MASK_ENV="$(cat "$MASK_DIR/github_env")"
}

# THE LIST IS DISCOVERED, NOT WRITTEN DOWN, and that is the difference between
# pinning the property and pinning today's three files. A fourth workflow taking
# the input -- another toolchain's `-cloudflare.yaml`, or a `-vercel.yaml` -- is
# guarded only if it is ITERATED, and a hand-maintained list is the one thing
# that cannot be relied on to be edited alongside the workflow that needs it. It
# is the same inversion the workflow-composition suite already names: a file that
# drops out of the list stops being looked at, and passes by not being checked.
#
# `build_env_secrets:` with the colon is the DECLARATION. The bare name also
# appears in prose in these files ("use `build_env_secrets` for those"), and a
# future workflow that only documents the input without accepting it would be
# swept in by the looser pattern and fail for having no step to extract.
MASK_WORKFLOWS=()
while IFS= read -r candidate; do
  MASK_WORKFLOWS+=("$candidate")
done < <(grep -l 'build_env_secrets:' "$SCRIPTS_DIR"/.github/workflows/*.yaml)

# An empty discovery would otherwise pass every assertion below by running none.
assert_true "build_env_secrets: the discovery found at least one workflow" \
  "[[ ${#MASK_WORKFLOWS[@]} -gt 0 ]]"

# INERT, and shaped only where the shape is the thing under test. Secret scanners
# match a vendor's token PREFIX as a pattern rather than verifying the value, so a
# fixture wearing a real one fails CI the day a rule is added and normalises
# token-like strings in the tree meanwhile -- and naming the prefix here to explain
# that would trip the same rule. What the assertion actually needs is an `=` INSIDE
# the value, which this keeps.
TOKEN_SHAPED='fixture-token-placeholder=_/inert+shape'
TRUNCATED='_/inert+shape'

for workflow in "${MASK_WORKFLOWS[@]}"; do
  name="$(basename "$workflow")"

  # Every workflow that accepts the input is EXECUTED, not merely grepped for the
  # literal `::add-mask::`. A copy that drifted to `${line%%=*}` (masking the KEY)
  # or to `cut -d= -f2` (the truncation below) satisfies a grep and still leaks.
  run_secrets_step "$workflow" \
    "$(printf 'FIRST=https://user@o123.ingest.example.invalid/456\nSECOND=%s\n' "$TOKEN_SHAPED")"

  assert_true "$name: the step succeeds on a two-line payload" \
    "[[ $MASK_STATUS -eq 0 ]]"
  assert_true "$name: the first value is masked" \
    "grep -qxF '::add-mask::https://user@o123.ingest.example.invalid/456' <<< \"\$MASK_OUT\""
  assert_true "$name: a value carrying its own '=' is masked WHOLE" \
    "grep -qxF '::add-mask::$TOKEN_SHAPED' <<< \"\$MASK_OUT\""
  assert_true "$name: no mask is registered for the truncated tail" \
    "! grep -qxF '::add-mask::$TRUNCATED' <<< \"\$MASK_OUT\""

  # The masking must not cost the step its original job.
  assert_true "$name: the payload still reaches GITHUB_ENV" \
    "grep -qF 'SECOND=$TOKEN_SHAPED' <<< \"\$MASK_ENV\""
  assert_true "$name: every line reaches GITHUB_ENV" \
    "grep -qF 'FIRST=https://user@o123.ingest.example.invalid/456' <<< \"\$MASK_ENV\""

  # WORKFLOW-COMMAND ESCAPING. The runner UNESCAPES `%25`, `%0D` and `%0A` in the
  # data of a `::` command, so a value containing the literal three characters
  # `%25` registers a mask for `%` -- a string that never appears -- and the real
  # value goes on printing. `%` must be escaped FIRST or the escapes are escaped
  # in turn.
  run_secrets_step "$workflow" "$(printf 'PCT=pct-%%25-value\nCR=has\rcarriage\n')"

  assert_true "$name: a '%' in a value is emitted escaped" \
    "grep -qxF '::add-mask::pct-%2525-value' <<< \"\$MASK_OUT\""
  assert_true "$name: the raw '%' form is NOT what is emitted" \
    "! grep -qxF '::add-mask::pct-%25-value' <<< \"\$MASK_OUT\""
  assert_true "$name: a carriage return in a value is emitted escaped" \
    "grep -qxF '::add-mask::has%0Dcarriage' <<< \"\$MASK_OUT\""

  # Nothing that is not an assignment, and nothing empty: `::add-mask::` on an
  # empty string is a runner error, and masking a bare word would redact an
  # ordinary English token everywhere it appeared in the log.
  run_secrets_step "$workflow" "$(printf 'NOT_AN_ASSIGNMENT\nEMPTY=\n\nREAL=value-here\n')"

  assert_true "$name: a line with no '=' registers no mask" \
    "! grep -q 'NOT_AN_ASSIGNMENT' <<< \"\$MASK_OUT\""
  assert_true "$name: an empty value registers no mask" \
    "! grep -qE '::add-mask::\s*$' <<< \"\$MASK_OUT\""
  assert_true "$name: the real value beside them is still masked" \
    "grep -qxF '::add-mask::value-here' <<< \"\$MASK_OUT\""
done
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All deployment provider tests passed!"
