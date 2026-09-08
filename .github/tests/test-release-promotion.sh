#!/usr/bin/env bash
# Regression test for release promotion: global/scripts/shared/promote-release.sh, the `promote`
# input of github/global/stages/40-delivery/release/action.yaml, and the `promote_release` wiring
# of every workflow that exposes it.
#
# A bump merged to `main` cuts a tag with the job's `GITHUB_TOKEN`, and GitHub starts no workflow
# run from an event that token caused -- so the tag run, the one every deploy job resolves
# `production` on, never started by itself. The promotion dispatches the calling workflow on the
# tag instead, `workflow_dispatch` being the one event exempt from the rule. Three classes of
# assertion pin that:
#
#   1. FUNCTIONAL -- the script is executed against a stub `curl` on PATH that answers a scripted
#      sequence of HTTP statuses and records what it was asked. This checks what the API is told
#      rather than what the script looks like it says: the file dispatched, the ref, the retries,
#      and which refusal maps to which advice.
#
#   2. SECURITY -- the token never reaches curl's argv. On a self-hosted runner argv is readable
#      in `ps` by every process on the host, so it travels as a config on stdin. The stub records
#      both, and the assertion greps a sentinel out of one and not the other.
#
#   3. STRUCTURAL -- the action guards the promotion on the input AND on a branch ref (a tag ref
#      is the promotion; dispatching it again would loop), runs it after the release exists, and
#      every workflow that exposes `promote_release` defaults it off, documents what the caller
#      must grant, and passes it through to where the dispatch happens. The three Cloudflare
#      workflows carry the `delivery > release` job they never had.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/global/scripts/shared/promote-release.sh"
ACTION="$REPO_ROOT/github/global/stages/40-delivery/release/action.yaml"
WORKFLOWS="$REPO_ROOT/.github/workflows"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1" condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (expected='$expected', actual='$actual')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# section <file> <indent> <key> -- the YAML block under <key> (a mapping key of exactly <indent>
# spaces), up to the next key at that depth or shallower. Written out rather than as an awk range
# because a range whose end pattern also matches its start line is one line long.
section() {
  awk -v ind="$2" -v key="$3" '
    { match($0, /^ */); depth = RLENGTH }
    !p && depth == ind && $0 == sprintf("%" ind "s", "") key ":" { p = 1; print; next }
    p && depth <= ind && $0 ~ /^ *[A-Za-z_-]+:$/ { exit }
    p { print }
  ' "$1"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------
# The stub. `curl` on PATH ahead of the real one: it answers the next status in the statuses
# file, prints it the way `--write-out '%{http_code}'` would, exits 7 with a `000` for a scripted
# transport failure, and records argv, the config it read from stdin, and the URL and body it was
# given -- one line per call, so a test can count calls as well as read them.
# ---------------------------------------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_LOG.argv"
config='' url='' data='' prev=''
for arg in "$@"; do
  case "$prev" in
    --config) [[ "$arg" == '-' ]] && config="$(cat)" ;;
    --data) data="$arg" ;;
  esac
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
  prev="$arg"
done
printf '%s\n' "$config" >> "$STUB_LOG.config"
printf '%s %s\n' "$url" "$data" >> "$STUB_LOG.calls"
statuses="$(cat "$STUB_LOG.statuses")"
status="${statuses%% *}"
rest="${statuses#* }"
[[ "$rest" == "$statuses" ]] && rest=''
printf '%s' "$rest" > "$STUB_LOG.statuses"
if [[ "$status" == '000' ]]; then
  echo 'curl: (7) Failed to connect to api.example.test port 443' >&2
  printf '000'
  exit 7
fi
printf '%s' "$status"
STUB
chmod +x "$STUB_BIN/curl"

# run_promotion <statuses> [NAME=value ...] -- runs the script under the stub in a scrubbed
# environment (a CI host has GITHUB_* set, and every one of them is what the script reads) that
# any argument may override. Leaves the exit code in RUN_EXIT, the combined output in
# $STUB_LOG.out and the requests in $STUB_LOG.calls. `LD_PRELOAD` is the one variable carried
# over: a host that resolves `/usr/bin/env` through a preload shim would otherwise lose the stub.
run_promotion() {
  local statuses="$1"
  shift
  STUB_LOG="$WORK/stub-$RANDOM$RANDOM"
  printf '%s' "$statuses" > "$STUB_LOG.statuses"
  : > "$STUB_LOG.calls"
  : > "$STUB_LOG.argv"
  : > "$STUB_LOG.config"
  set +e
  env -i PATH="$STUB_BIN:$PATH" HOME="$WORK" ${LD_PRELOAD:+LD_PRELOAD="$LD_PRELOAD"} \
    PROMOTE_TAG='1.2.3' \
    GH_TOKEN='sentinel-token-3f9a' \
    GITHUB_REF='refs/heads/main' \
    GITHUB_WORKFLOW_REF='acme/widgets/.github/workflows/default.yaml@refs/heads/main' \
    GITHUB_REPOSITORY='acme/widgets' \
    GITHUB_API_URL='https://api.example.test' \
    PROMOTE_RETRY_DELAY='0' \
    STUB_LOG="$STUB_LOG" \
    "$@" \
    sh "$SCRIPT" > "$STUB_LOG.out" 2>&1
  RUN_EXIT=$?
  set -e
}

calls() { wc -l < "$STUB_LOG.calls" | tr -d ' '; }
said() { grep -q -- "$1" "$STUB_LOG.out"; }

echo "=== Release promotion: dispatching the tag run ==="

run_promotion '204'
assert_equals "an accepted dispatch (204) exits 0" '0' "$RUN_EXIT"
assert_equals "exactly one request is made" '1' "$(calls)"
assert_equals "it dispatches the CALLER's workflow file, on the tag, at the API the runner names" \
  'https://api.example.test/repos/acme/widgets/actions/workflows/default.yaml/dispatches {"ref":"1.2.3"}' \
  "$(cat "$STUB_LOG.calls")"
assert_true "the summary names the file and the tag" "said 'dispatched default.yaml on 1.2.3'"
assert_true "the token travels in the config on stdin" "grep -q 'Authorization: Bearer sentinel-token-3f9a' '$STUB_LOG.config'"
assert_true "the token never reaches argv" "! grep -q 'sentinel-token-3f9a' '$STUB_LOG.argv'"
assert_true "the token is not echoed in the output" "! said 'sentinel-token-3f9a'"
assert_true "the body is declared as JSON, not curl's form-encoded default" \
  "grep -q -- \"--header Content-Type: application/json\" '$STUB_LOG.argv'"
assert_true "the transport is pinned to HTTPS, redirects included: the token is on this request" \
  "grep -q -- \"--proto =https\" '$STUB_LOG.argv' && grep -q -- \"--proto-redir =https\" '$STUB_LOG.argv'"

run_promotion '204' PROMOTE_TAG='v1.2.3' \
  GITHUB_WORKFLOW_REF='acme/widgets/.github/workflows/pipeline.yml@refs/heads/release/2024@q3'
assert_equals "a prefixed tag is dispatched as given, and a branch carrying '@' does not eat the file name" \
  'https://api.example.test/repos/acme/widgets/actions/workflows/pipeline.yml/dispatches {"ref":"v1.2.3"}' \
  "$(cat "$STUB_LOG.calls")"

echo ""
echo "=== Release promotion: every refusal names its fix ==="

run_promotion '403'
assert_equals "403 fails the step" '1' "$RUN_EXIT"
assert_true "403 says the calling job must be granted 'actions: write'" "said 'actions: write'"
assert_equals "403 is not retried" '1' "$(calls)"

run_promotion '404'
assert_equals "404 fails the step" '1' "$RUN_EXIT"
assert_true "404 names the file it looked for and where the name came from" "said 'default.yaml was not found' && said 'GITHUB_WORKFLOW_REF'"

run_promotion '422'
assert_equals "422 fails the step" '1' "$RUN_EXIT"
assert_true "422 says the calling workflow needs 'workflow_dispatch:'" "said 'workflow_dispatch'"

run_promotion '401'
assert_equals "401 fails the step" '1' "$RUN_EXIT"

run_promotion '301'
assert_equals "a redirect fails the step rather than being followed" '1' "$RUN_EXIT"
assert_true "...naming the rename that causes it" "said 'a redirect' && said 'RENAMED'"
assert_equals "...and is not retried" '1' "$(calls)"

run_promotion '418'
assert_equals "an unexpected status fails the step" '1' "$RUN_EXIT"
assert_true "an unexpected status is reported with its number" "said 'unexpected HTTP 418'"

run_promotion '403'
assert_true "every refusal leaves the by-hand command behind" "said 'gh workflow run default.yaml --repo acme/widgets --ref 1.2.3'"

echo ""
echo "=== Release promotion: transient failures are retried, refusals are not ==="

run_promotion '500 000 204'
assert_equals "a 5xx, then a transport failure, then a 204 succeeds" '0' "$RUN_EXIT"
assert_equals "...after three requests" '3' "$(calls)"

run_promotion '500 500 500'
assert_equals "three 5xx in a row fail the step" '1' "$RUN_EXIT"
assert_equals "...after exactly PROMOTE_ATTEMPTS requests" '3' "$(calls)"
assert_true "...and say how many times it tried" "said 'failed 3 times'"

run_promotion '502 502 502 502 204' PROMOTE_ATTEMPTS='5'
assert_equals "PROMOTE_ATTEMPTS raises the ceiling" '0' "$RUN_EXIT"
assert_equals "...to five requests" '5' "$(calls)"

echo ""
echo "=== Release promotion: when there is nothing to dispatch ==="

run_promotion '204' GITHUB_REF='refs/tags/1.2.3'
assert_equals "a tag ref exits 0" '0' "$RUN_EXIT"
assert_equals "...without a request: that run IS the promotion" '0' "$(calls)"
assert_true "...and says so" "said 'nothing to dispatch'"

run_promotion '204' PROMOTE_DRY_RUN='true'
assert_equals "a dry run exits 0" '0' "$RUN_EXIT"
assert_equals "...without a request" '0' "$(calls)"
assert_true "...and prints the request it would have sent" "said 'DRY RUN: POST https://api.example.test/repos/acme/widgets/actions/workflows/default.yaml/dispatches'"

run_promotion '204' PROMOTE_TAG=''
assert_true "an empty tag is refused before any request" "[[ $RUN_EXIT -ne 0 ]] && [[ $(calls) -eq 0 ]]"

run_promotion '204' GH_TOKEN=''
assert_equals "a missing token is refused before any request" '1' "$RUN_EXIT"
assert_equals "...without a request" '0' "$(calls)"

run_promotion '204' GITHUB_WORKFLOW_REF=''
assert_equals "no workflow ref is refused before any request" '1' "$RUN_EXIT"

echo ""
echo "=== Release promotion: the action wires the script ==="

section "$ACTION" 2 promote > "$WORK/action-input"
assert_true "the script is executable" "[[ -x '$SCRIPT' ]]"
assert_true "the action declares a 'promote' input" "[[ -s '$WORK/action-input' ]]"
assert_true "...that defaults to 'false'" "grep -q \"default: 'false'\" '$WORK/action-input'"
assert_true "the action runs the script from the checked-out scripts tree" "grep -q 'run: \$SCRIPTS_DIR/global/scripts/shared/promote-release.sh' '$ACTION'"
assert_true "the action hands the script the tag it created, prefix included" "grep -q \"PROMOTE_TAG: '\\\${{ inputs.tag_prefix }}\\\${{ steps.extract.outputs.tag_name }}'\" '$ACTION'"
assert_true "the action hands the script the job token" "grep -q \"GH_TOKEN: '\\\${{ github.token }}'\" '$ACTION'"
assert_equals "both promotion steps are guarded on the input, on a release having been cut, and on a branch ref" '2' \
  "$(grep -c "if: \"inputs.promote == 'true' && steps.extract.outputs.skip_release != 'true' && startsWith(github.ref, 'refs/heads/')\"" "$ACTION")"
assert_true "the promotion runs after the release exists" \
  "[[ \$(grep -n \"name: 'Create Release'\" '$ACTION' | cut -d: -f1) -lt \$(grep -n \"name: 'Promote Release'\" '$ACTION' | cut -d: -f1) ]]"

echo ""
echo "=== Release promotion: the workflows expose and forward the input ==="

for workflow in yarn-cloudflare npm-cloudflare dart-cloudflare go-docker go-flyio go-render; do
  section "$WORKFLOWS/$workflow.yaml" 6 promote_release > "$WORK/input"
  assert_true "$workflow.yaml declares promote_release as an optional boolean that is off by default" \
    "grep -q \"type: 'boolean'\" '$WORK/input' && grep -q 'required: false' '$WORK/input' && grep -q 'default: false' '$WORK/input'"
  assert_true "$workflow.yaml tells the caller what to grant" \
    "grep -q 'actions: write' '$WORK/input' && grep -q 'workflow_dispatch' '$WORK/input'"
done

for pair in yarn-cloudflare:yarn npm-cloudflare:npm dart-cloudflare:dart; do
  workflow="${pair%%:*}"
  toolchain="${pair##*:}"
  section "$WORKFLOWS/$workflow.yaml" 2 delivery-release > "$WORK/job"
  assert_true "$workflow.yaml carries the 'delivery > release' job" "grep -q \"name: 'delivery > release'\" '$WORK/job'"
  assert_true "$workflow.yaml's release job needs the quality gate" "grep -q \"needs: \\[ '$toolchain' \\]\" '$WORK/job'"
  assert_true "$workflow.yaml's release job runs on a bump merged to main only" \
    "grep -q \"github.event_name == 'push' && github.ref == 'refs/heads/main'\" '$WORK/job' && grep -q 'chore/bump-' '$WORK/job' && grep -q 'chore(bump)' '$WORK/job'"
  assert_true "$workflow.yaml's release job passes promote_release to the action" "grep -q 'promote: \${{ inputs.promote_release }}' '$WORK/job'"
  assert_true "$workflow.yaml's release job resolves its runner from runs_on" "grep -q 'runs-on: \${{ fromJSON(inputs.runs_on) }}' '$WORK/job'"
done

section "$WORKFLOWS/go-docker.yaml" 2 delivery-release > "$WORK/job"
assert_true "go-docker.yaml passes promote_release to the action" "grep -q 'promote: \${{ inputs.promote_release }}' '$WORK/job'"
for workflow in go-flyio go-render; do
  section "$WORKFLOWS/$workflow.yaml" 2 go-docker > "$WORK/job"
  assert_true "$workflow.yaml forwards promote_release to go-docker.yaml" "grep -q 'promote_release: \${{ inputs.promote_release }}' '$WORK/job'"
done

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
