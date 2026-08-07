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
      NETLIFY_AUTH_TOKEN NETLIFY_SITE_ID NETLIFY_OUTPUT_DIRECTORY NETLIFY_DEPLOY_MESSAGE \
      RENDER_API_KEY RENDER_SERVICE_ID RENDER_DEPLOY_HOOK_URL \
      FLY_API_TOKEN FLY_APP_NAME FLY_CONFIG FLY_STRATEGY \
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
assert_true "render: an API key without a service id fails the job" "[[ $STATUS -eq 1 ]]"

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

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All deployment provider tests passed!"
