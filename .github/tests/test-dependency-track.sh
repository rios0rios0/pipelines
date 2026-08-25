#!/usr/bin/env bash
# ARGV, CURL_STDIN, STDOUT, RC and GITLAB_ABSTRACT are read only from inside the
# single-quoted condition strings that `assert_true` evaluates, which ShellCheck
# cannot follow — so every one of them reads as unused. The alternative is
# passing five values into each assertion, which would bury what each test is
# actually claiming.
# shellcheck disable=SC2034

set -e

# Test script for the Dependency-Track BOM uploader
# (global/scripts/tools/dependency-track/run.sh) and its cross-platform wiring.
#
# WHY THIS EXISTS. Dependency-Track identifies a project by the PAIR
# `(name, version)` — each pair is a separate entity with its own UUID and
# findings, and there is no "project that holds several versions". An uploader
# that sends the release version with `autoCreate=true` therefore mints a
# permanent new project on every bump. One consuming instance reached 2585
# projects across 77 names that way, with every upload returning HTTP 200 the
# whole time. Nothing in this failure mode is visible from a job's exit code,
# which is why each leg of it is pinned by an assertion below.
#
# The uploader is exercised FOR REAL: a stub `curl` is put on PATH, run.sh is
# invoked, and the recorded argv is asserted against. That checks what the tool
# is actually told rather than what the script looks like it says — the same
# approach as .github/tests/test-dependency-check.sh.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR
RUN_SH="$SCRIPTS_DIR/global/scripts/tools/dependency-track/run.sh"
GITLAB_ABSTRACT="$SCRIPTS_DIR/gitlab/global/stages/35-management/abstracts.yaml"

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

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Stands up a throwaway project holding $BOM as build/reports/bom.json, puts a
# stub `curl` on PATH that records its argv AND its stdin, runs the script, and
# leaves the results in $ARGV / $CURL_STDIN / $STDOUT / $RC.
run_against_stub() {
  local bomContent="$1"
  shift

  local projectDir="$WORK_DIR/project"
  rm -rf "$projectDir"
  mkdir -p "$projectDir/bin" "$projectDir/build/reports"

  if [[ "$bomContent" != 'NO_BOM' ]]; then
    printf '%s' "$bomContent" > "$projectDir/build/reports/bom.json"
  fi

  local argvFile="$projectDir/argv.txt"
  local stdinFile="$projectDir/curl-stdin.txt"
  cat > "$projectDir/bin/curl" <<EOF
#!/usr/bin/env sh
printf '%s\n' "\$@" > '$argvFile'
cat > '$stdinFile'
# run.sh reads this as the HTTP status from --write-out.
printf '200'
EOF
  chmod +x "$projectDir/bin/curl"

  : > "$argvFile"
  : > "$stdinFile"

  set +e
  (
    cd "$projectDir"
    # Clear every variable under test so each case starts from a known state;
    # a leaked CI variable from the host would make these results meaningless.
    unset CI_COMMIT_TAG CI_COMMIT_BRANCH CI_DEFAULT_BRANCH CI_MERGE_REQUEST_IID
    unset BUILD_SOURCEBRANCH BUILD_REASON GITHUB_REF
    unset DEPENDENCY_TRACK_IS_LATEST DEPENDENCY_TRACK_DEFAULT_BRANCH
    unset DEPENDENCY_TRACK_PARENT_NAME DEPENDENCY_TRACK_PARENT_VERSION
    unset DEPENDENCY_TRACK_PROJECT_NAME DEPENDENCY_TRACK_PROJECT_VERSION
    unset DEPENDENCY_TRACK_UPLOAD_ON_PULL_REQUEST
    export PATH="$projectDir/bin:$PATH"
    export SCRIPTS_DIR
    export REPORT_PATH='build/reports'
    export DEPENDENCY_TRACK_HOST_URL='https://dt.example.com'
    export DEPENDENCY_TRACK_TOKEN='fixture-token-placeholder'
    env "$@" "$RUN_SH" > "$projectDir/stdout.txt" 2>&1
  )
  RC=$?
  set -e

  ARGV="$(cat "$argvFile")"
  CURL_STDIN="$(cat "$stdinFile")"
  STDOUT="$(cat "$projectDir/stdout.txt")"
}

# A BOM shaped the way cyclonedx-gomod / cyclonedx-npm actually emit one.
BOM_OK='{"bomFormat":"CycloneDX","specVersion":"1.6","metadata":{"component":{"type":"application","name":"my-app","version":"7.8.0"}},"components":[]}'
BOM_SCOPED='{"bomFormat":"CycloneDX","specVersion":"1.6","metadata":{"component":{"type":"application","name":"@org/app","version":"1.0.0"}},"components":[]}'
BOM_NO_COMPONENT='{"bomFormat":"CycloneDX","specVersion":"1.6","components":[]}'
BOM_NO_VERSION='{"bomFormat":"CycloneDX","specVersion":"1.6","metadata":{"component":{"type":"application","name":"my-app"}},"components":[]}'

echo '============================================================'
echo 'Test 1: a BOM with no metadata.component fails loudly'
echo '============================================================'
# `jq -r` prints the STRING `null` for a missing key, and `null` is a perfectly
# valid project name — so this used to create a project literally called `null`
# and keep updating it forever, with a green job every time.
run_against_stub "$BOM_NO_COMPONENT"
assert_true 'exits non-zero instead of uploading' '[[ $RC -ne 0 ]]'
assert_true 'never calls curl' '[[ -z "$ARGV" ]]'
assert_true 'names the missing field' '[[ "$STDOUT" == *"metadata.component.name"* ]]'
assert_true 'never sends a project named null' '[[ "$ARGV" != *"projectName=null"* ]]'

echo '============================================================'
echo 'Test 2: the happy path sends the identity fields'
echo '============================================================'
run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main
assert_true 'exits zero' '[[ $RC -eq 0 ]]'
assert_true 'sends projectName' '[[ "$ARGV" == *"projectName=my-app"* ]]'
assert_true 'sends projectVersion' '[[ "$ARGV" == *"projectVersion=7.8.0"* ]]'
assert_true 'sends autoCreate' '[[ "$ARGV" == *"autoCreate=true"* ]]'
assert_true 'sends the BOM file' '[[ "$ARGV" == *"bom=@build/reports/bom.json"* ]]'

echo '============================================================'
echo 'Test 3: the API key never reaches argv'
echo '============================================================'
# argv is world-readable through `ps` and /proc/<pid>/cmdline, which on a shared
# or self-hosted runner means every other job on that host. Same rule the deploy
# providers and the Dependency-Check runner already follow.
assert_true 'token is absent from argv' '[[ "$ARGV" != *"fixture-token-placeholder"* ]]'
assert_true 'no X-Api-Key header on argv' '[[ "$ARGV" != *"X-Api-Key"* ]]'
assert_true 'token is passed on stdin instead' '[[ "$CURL_STDIN" == *"X-Api-Key: fixture-token-placeholder"* ]]'
assert_true 'stdin is a curl config header line' '[[ "$CURL_STDIN" == "header = "* ]]'

echo '============================================================'
echo 'Test 4: the scoped-name normalisation is applied'
echo '============================================================'
# The GitLab inline curl used to skip this, so a scoped npm package uploaded as
# `@org/app` from GitLab and `@org-app` from Azure — two projects, one app.
run_against_stub "$BOM_SCOPED" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main
assert_true 'slash becomes a dash' '[[ "$ARGV" == *"projectName=@org-app"* ]]'
assert_true 'no raw slash in the name' '[[ "$ARGV" != *"projectName=@org/app"* ]]'

# ...and it is applied to the OVERRIDE as well, not only to the BOM-derived
# name. An override names the same project the BOM path would produce, so a
# variable that skipped normalisation would let one platform file `@org/app`
# while another filed `@org-app` — re-opening the split from the line above
# through the very knob added to control it. (Copilot, PR #612.)
run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main \
  DEPENDENCY_TRACK_PROJECT_NAME='@org/override'
assert_true 'override is normalised too' '[[ "$ARGV" == *"projectName=@org-override"* ]]'
assert_true 'override keeps no raw slash' '[[ "$ARGV" != *"projectName=@org/override"* ]]'

echo '============================================================'
echo 'Test 4b: a token containing a line break is refused'
echo '============================================================'
# curl's config format is LINE-based, so a newline ends the `header = "..."`
# directive regardless of quoting and everything after it parses as further
# directives — `output = ...` to capture the response, another `header = ...`
# to tamper with the request. Escaping backslashes and quotes does not close
# that, because those are within-line concerns. (Copilot, PR #612.)
# `$'\n'` (ANSI-C quoting), NOT `$(printf '\n')` — command substitution strips
# trailing newlines, so the `$(...)` form yields an empty string and the fixture
# silently carries no line break at all. It then "passes" against a script with
# no guard whatsoever, which is the worst way for a security test to be wrong.
run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main \
  "DEPENDENCY_TRACK_TOKEN=good"$'\n'"output = /tmp/pwned"
assert_true 'exits non-zero' '[[ $RC -ne 0 ]]'
assert_true 'never calls curl' '[[ -z "$ARGV" ]]'
assert_true 'no injected directive reaches curl stdin' '[[ "$CURL_STDIN" != *"output = /tmp/pwned"* ]]'
assert_true 'names the cause' '[[ "$STDOUT" == *"line break"* ]]'

echo '============================================================'
echo 'Test 5: isLatest is gated on the ref'
echo '============================================================'
# At most one version per name carries isLatest, and a collection project with
# AGGREGATE_LATEST_VERSION_CHILDREN reads its metrics from that child. Asserting
# it from every run moved the flag backwards onto older versions.
run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main
assert_true 'GitLab default branch  -> isLatest=true' '[[ "$ARGV" == *"isLatest=true"* ]]'

run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=feature/x CI_DEFAULT_BRANCH=main
assert_true 'GitLab feature branch  -> isLatest=false' '[[ "$ARGV" == *"isLatest=false"* ]]'

run_against_stub "$BOM_OK" CI_COMMIT_TAG=v1.2.3
assert_true 'GitLab tag             -> isLatest=true' '[[ "$ARGV" == *"isLatest=true"* ]]'

run_against_stub "$BOM_OK" BUILD_SOURCEBRANCH=refs/tags/v1.2.3
assert_true 'Azure tag              -> isLatest=true' '[[ "$ARGV" == *"isLatest=true"* ]]'

run_against_stub "$BOM_OK" GITHUB_REF=refs/tags/v1.2.3
assert_true 'GitHub tag             -> isLatest=true' '[[ "$ARGV" == *"isLatest=true"* ]]'

# Azure publishes no default-branch variable, so an unaided branch build cannot
# be classified. It must still UPLOAD (silence is worse than an extra project)
# but must not claim the latest flag.
run_against_stub "$BOM_OK" BUILD_SOURCEBRANCH=refs/heads/main
assert_true 'Azure branch, unaided  -> uploads' '[[ "$ARGV" == *"projectName=my-app"* ]]'
assert_true 'Azure branch, unaided  -> isLatest=false' '[[ "$ARGV" == *"isLatest=false"* ]]'

run_against_stub "$BOM_OK" BUILD_SOURCEBRANCH=refs/heads/main DEPENDENCY_TRACK_DEFAULT_BRANCH=refs/heads/main
assert_true 'Azure branch + hint    -> isLatest=true' '[[ "$ARGV" == *"isLatest=true"* ]]'

run_against_stub "$BOM_OK" BUILD_SOURCEBRANCH=refs/heads/main DEPENDENCY_TRACK_DEFAULT_BRANCH=main
assert_true 'the hint accepts a bare branch name too' '[[ "$ARGV" == *"isLatest=true"* ]]'

run_against_stub "$BOM_OK"
assert_true 'no CI at all           -> isLatest=false' '[[ "$ARGV" == *"isLatest=false"* ]]'

run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=feature/x CI_DEFAULT_BRANCH=main DEPENDENCY_TRACK_IS_LATEST=true
assert_true 'an explicit override wins' '[[ "$ARGV" == *"isLatest=true"* ]]'

echo '============================================================'
echo 'Test 6: a merge/pull request never creates a project'
echo '============================================================'
# The single largest contributor to sprawl: a PR whose version file is already
# bumped mints that version's project before the merge, and keeps it if the
# merge never happens.
run_against_stub "$BOM_OK" CI_MERGE_REQUEST_IID=42
assert_true 'GitLab MR    -> skipped'    '[[ -z "$ARGV" ]]'
assert_true 'GitLab MR    -> exit 0'     '[[ $RC -eq 0 ]]'
assert_true 'GitLab MR    -> says why'   '[[ "$STDOUT" == *"pull request"* ]]'

run_against_stub "$BOM_OK" BUILD_REASON=PullRequest
assert_true 'Azure PR     -> skipped'    '[[ -z "$ARGV" ]]'

run_against_stub "$BOM_OK" BUILD_SOURCEBRANCH=refs/pull/7/merge
assert_true 'Azure PR ref -> skipped'    '[[ -z "$ARGV" ]]'

run_against_stub "$BOM_OK" GITHUB_REF=refs/pull/7/merge
assert_true 'GitHub PR    -> skipped'    '[[ -z "$ARGV" ]]'

run_against_stub "$BOM_OK" CI_MERGE_REQUEST_IID=42 DEPENDENCY_TRACK_UPLOAD_ON_PULL_REQUEST=true
assert_true 'the opt-in restores the upload' '[[ "$ARGV" == *"projectName=my-app"* ]]'

echo '============================================================'
echo 'Test 7: the collection parent is sent when configured'
echo '============================================================'
# BomResource.uploadBom resolves the parent ONLY inside its
# `if (project == null && autoCreate)` branch — verified in both 4.14 and 5.0.5
# — so these fields parent the projects this pipeline CREATES and can never
# re-parent one already in the portfolio.
run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main \
  DEPENDENCY_TRACK_PARENT_NAME=my-app
assert_true 'sends parentName' '[[ "$ARGV" == *"parentName=my-app"* ]]'
assert_true 'omits parentVersion when unset' '[[ "$ARGV" != *"parentVersion="* ]]'

run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main \
  DEPENDENCY_TRACK_PARENT_NAME=my-app DEPENDENCY_TRACK_PARENT_VERSION=collection
assert_true 'sends parentVersion when set' '[[ "$ARGV" == *"parentVersion=collection"* ]]'

run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main
assert_true 'sends no parent by default' '[[ "$ARGV" != *"parentName="* ]]'

echo '============================================================'
echo 'Test 8: identity overrides and the versionless case'
echo '============================================================'
run_against_stub "$BOM_OK" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main \
  DEPENDENCY_TRACK_PROJECT_NAME=override-name DEPENDENCY_TRACK_PROJECT_VERSION=override-version
assert_true 'the name override wins'    '[[ "$ARGV" == *"projectName=override-name"* ]]'
assert_true 'the version override wins' '[[ "$ARGV" == *"projectVersion=override-version"* ]]'

# A missing version is NOT fatal: Dependency-Track trims an empty projectVersion
# to null and keeps ONE versionless project that every build updates — strictly
# better than one project pinned to the literal version `null`.
run_against_stub "$BOM_NO_VERSION" CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main
assert_true 'versionless BOM still uploads' '[[ $RC -eq 0 ]]'
assert_true 'versionless BOM warns'         '[[ "$STDOUT" == *"versionless"* ]]'
assert_true 'never sends the literal null'  '[[ "$ARGV" != *"projectVersion=null"* ]]'

echo '============================================================'
echo 'Test 9: a missing BOM is skipped, not failed'
echo '============================================================'
# Consumers without a language-specific BOM generator hit this on every build.
run_against_stub 'NO_BOM' CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main
assert_true 'exits zero'      '[[ $RC -eq 0 ]]'
assert_true 'never calls curl' '[[ -z "$ARGV" ]]'

echo '============================================================'
echo 'Test 10: cross-platform wiring parity'
echo '============================================================'
# A divergent second implementation is exactly what produced the duplication
# this whole change exists to remove, and three files that are each valid YAML
# on their own is something nothing else in CI would catch.
assert_true 'GitLab abstract calls the shared script' \
  'grep -q "global/scripts/tools/dependency-track/run.sh" "$GITLAB_ABSTRACT"'
assert_true 'GitLab abstract no longer inlines its own curl' \
  '! grep -q "api/v1/bom" "$GITLAB_ABSTRACT"'
assert_true 'GitLab abstract no longer uploads from merge requests' \
  '! grep -A6 "^\.dependency-track:" "$GITLAB_ABSTRACT" | grep -q "CI_MERGE_REQUEST_IID"'

# The Go job defines its own `script:`, and GitLab `extends` REPLACES rather
# than appends — so it generated a BOM and threw it away, green, forever.
assert_true 'GitLab Go job actually uploads its BOM' \
  'grep -q "tools/dependency-track/run.sh" "$SCRIPTS_DIR/gitlab/golang/stages/35-management/go.yaml"'

azure_dt_files=$(grep -rl 'report_dependency_track' "$SCRIPTS_DIR/azure-devops" --include='*.yaml')
azure_total=0
azure_gated=0
for f in $azure_dt_files; do
  azure_total=$((azure_total + 1))
  if grep -q "ne(variables\['Build.Reason'\], 'PullRequest')" "$f"; then
    azure_gated=$((azure_gated + 1))
  fi
done
assert_true "every Azure dependency-track job is PR-gated ($azure_gated/$azure_total)" \
  '[[ $azure_total -gt 0 && $azure_gated -eq $azure_total ]]'

# Azure DevOps publishes no default-branch variable. A comparison against
# `Build.Repository.DefaultBranch` reads correct and is always an empty string,
# so it would disable every upload without a single error anywhere.
#
# Comments are stripped before matching, on the same reasoning as
# test-supply-chain.sh's `drop_comments`: the Azure templates carry a comment
# explaining why that variable must not be used, and a naive grep is failed by
# its own explanation.
assert_true 'no template invents Build.Repository.DefaultBranch' \
  '! grep -rHn "Build.Repository.DefaultBranch" "$SCRIPTS_DIR/azure-devops" --include="*.yaml" | grep -vE ":[0-9]+:[[:space:]]*(-[[:space:]]*)?#" | grep -q .'
assert_true 'the runner does not read BUILD_REPOSITORY_DEFAULTBRANCH either' \
  '! grep -q "BUILD_REPOSITORY_DEFAULTBRANCH" "$RUN_SH"'

# The jobs that hand-install tooling now need git, because the shared script is
# fetched with it.
for f in "$SCRIPTS_DIR"/gitlab/*/stages/35-management/*.yaml; do
  if grep -q 'curl jq' "$f"; then
    assert_true "$(basename "$(dirname "$(dirname "$(dirname "$f")")")") installs git alongside curl/jq" \
      'grep -q "curl jq git" "$f"'
  fi
done

echo
echo '============================================================'
echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
echo '============================================================'
[[ $TESTS_FAILED -eq 0 ]]
