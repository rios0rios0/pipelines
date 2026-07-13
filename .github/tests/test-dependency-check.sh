#!/usr/bin/env bash
set -e

# Test script for the OWASP Dependency-Check runner
# (global/scripts/languages/java/dependency-check/run.sh).
#
# The job this guards used to run for 5h45m and get cancelled, because the NVD API key never reached
# the tool (both plugins ignore a bare NVD_API_KEY environment variable) and the CVE database was
# never written to the directory the pipelines cached. Every assertion below pins one leg of that
# failure, so the regression cannot come back silently.
#
# The Maven and Gradle cases are exercised for real: a stub build tool is put on PATH, run.sh is
# invoked, and the recorded argv is asserted against. That checks what the tool is actually told,
# rather than what the script looks like it says.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/java/dependency-check/run.sh"
INIT_GRADLE="$SCRIPTS_DIR/global/scripts/languages/java/dependency-check/init.gradle"
ACTION="$SCRIPTS_DIR/github/java/stages/20-security/dependency-check/action.yaml"

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

# Stands up a throwaway project with a stub build tool on PATH that records the argv it was called
# with, runs the script against it, and leaves the result in $ARGV for assertions.
run_against_stub() {
  local buildFile="$1" # 'pom.xml' or 'build.gradle'
  local stubName="$2"  # 'mvn' or 'gradle'
  shift 2

  local projectDir="$WORK_DIR/project"
  rm -rf "$projectDir"
  mkdir -p "$projectDir/bin"
  touch "$projectDir/$buildFile"

  local argvFile="$projectDir/argv.txt"
  cat > "$projectDir/bin/$stubName" <<EOF
#!/usr/bin/env sh
printf '%s\n' "\$@" > '$argvFile'
EOF
  chmod +x "$projectDir/bin/$stubName"

  (
    cd "$projectDir"
    # `env -i` would drop PATH; unset only the variables under test so each case starts clean.
    unset NVD_API_KEY NVD_DATAFEED_URL NVD_VALID_FOR_HOURS DEPENDENCY_CHECK_DATA_DIR
    export PATH="$projectDir/bin:$PATH"
    export SCRIPTS_DIR
    env "$@" "$RUN_SH" > "$projectDir/stdout.txt" 2>&1
  )

  ARGV="$(cat "$argvFile")"
  STDOUT="$(cat "$projectDir/stdout.txt")"
}

# =============================================================================
# Test 1: Maven — the API key reaches the plugin, and does so without leaking
# =============================================================================
echo "TEST 1: Maven passes the NVD API key by variable name, never by value"
# given a project with an NVD API key in the environment
# when dependency-check runs
run_against_stub 'pom.xml' 'mvn' NVD_API_KEY='super-secret-key-value'
# then the plugin is told which variable to read the key from...
assert_true "passes -DnvdApiKeyEnvironmentVariable so the plugin reads NVD_API_KEY itself" \
  "grep -qx -- '-DnvdApiKeyEnvironmentVariable=NVD_API_KEY' <<< \"\$ARGV\""
# ...and the key itself never lands in argv, where `mvn -X` would print it (GHSA-qqhq-8r2c-c3f5)
assert_true "never puts the key's value on the command line" \
  "! grep -q 'super-secret-key-value' <<< \"\$ARGV\""
assert_true "never uses the leaky -DnvdApiKey property" \
  "! grep -q -- '-DnvdApiKey=' <<< \"\$ARGV\""
# and with a key it uses the authenticated API rather than the datafeed
assert_true "does not fall back to the datafeed when a key is present" \
  "! grep -q -- '-DnvdDatafeedUrl' <<< \"\$ARGV\""

# =============================================================================
# Test 2: Maven — the CVE database is pinned to the cached directory
# =============================================================================
echo "TEST 2: Maven pins the CVE database into the directory the pipelines cache"
# given no explicit data directory
# when dependency-check runs
run_against_stub 'pom.xml' 'mvn' NVD_API_KEY='k'
# then the database goes to ./.owasp -- the path every platform caches -- as an absolute path,
# because both plugins reject a relative one. Left to itself Maven would default it into
# ~/.m2/repository/org/owasp/dependency-check-data/, which the pipelines never cached.
assert_true "passes an absolute -DdataDirectory ending in /.owasp" \
  "grep -qE -- '^-DdataDirectory=/.*/\.owasp$' <<< \"\$ARGV\""
assert_true "reuses a cached database for 24h instead of the 4h default" \
  "grep -qx -- '-DnvdValidForHours=24' <<< \"\$ARGV\""
assert_true "honours DEPENDENCY_CHECK_DATA_DIR when set" \
  "run_against_stub 'pom.xml' 'mvn' NVD_API_KEY='k' DEPENDENCY_CHECK_DATA_DIR='/tmp/custom-nvd'; \
   grep -qx -- '-DdataDirectory=/tmp/custom-nvd' <<< \"\$ARGV\""

# =============================================================================
# Test 3: no API key falls back to the datafeed, never to the throttled API
# =============================================================================
echo "TEST 3: a keyless run uses the NVD datafeed instead of the rate-limited API"
# given no API key at all
# when dependency-check runs
run_against_stub 'pom.xml' 'mvn'
# then it downloads NIST's gzipped feeds rather than paginating ~174 API pages at 5 requests/30s
assert_true "falls back to the NVD datafeed" \
  "grep -q -- '-DnvdDatafeedUrl=https://nvd.nist.gov/feeds/json/cve/2.0/' <<< \"\$ARGV\""
assert_true "does not claim an API key it does not have" \
  "! grep -q -- '-DnvdApiKeyEnvironmentVariable' <<< \"\$ARGV\""
assert_true "warns that the run would be faster and fresher with a key" \
  "grep -q 'nvd.nist.gov/developers/request-an-api-key' <<< \"\$STDOUT\""
# and an explicit mirror still wins over the default
assert_true "honours a self-hosted NVD_DATAFEED_URL mirror" \
  "run_against_stub 'pom.xml' 'mvn' NVD_DATAFEED_URL='https://mirror.internal/nvd/'; \
   grep -qx -- '-DnvdDatafeedUrl=https://mirror.internal/nvd/' <<< \"\$ARGV\""

# =============================================================================
# Test 4: Azure DevOps leaves undefined variables unexpanded
# =============================================================================
echo "TEST 4: an unexpanded Azure DevOps macro is not mistaken for an API key"
# given Azure DevOps passed `$(NVD_API_KEY)` verbatim because the variable is not defined
# when dependency-check runs
run_against_stub 'pom.xml' 'mvn' NVD_API_KEY='$(NVD_API_KEY)'
# then it is treated as no key. Handing that string to the NVD earns a 403 on every request, which is
# worse than no key at all: the datafeed fallback would never engage.
assert_true "treats the literal macro as an absent key" \
  "! grep -q -- '-DnvdApiKeyEnvironmentVariable' <<< \"\$ARGV\""
assert_true "falls back to the datafeed instead" \
  "grep -q -- '-DnvdDatafeedUrl=' <<< \"\$ARGV\""

# =============================================================================
# Test 5: Gradle is configured through an init script
# =============================================================================
echo "TEST 5: Gradle is configured through an init script, not a dead env var"
# given a Gradle project
# when dependency-check runs
run_against_stub 'build.gradle' 'gradle' NVD_API_KEY='k'
# then the settings are injected via --init-script. The Gradle plugin reads them ONLY from its
# `dependencyCheck` extension -- it consults neither the environment nor system properties -- so the
# OWASP_PATH export the pipelines used to rely on was a no-op and the database silently went to
# $GRADLE_USER_HOME/dependency-check-data/, never into the cached directory.
assert_true "invokes dependencyCheckAnalyze" \
  "grep -qx 'dependencyCheckAnalyze' <<< \"\$ARGV\""
assert_true "passes --init-script" \
  "grep -qx -- '--init-script' <<< \"\$ARGV\""
assert_true "points --init-script at the shipped init.gradle" \
  "grep -qx -- '.*/global/scripts/languages/java/dependency-check/init.gradle' <<< \"\$ARGV\""
assert_true "the init script it points at exists" "[ -f '$INIT_GRADLE' ]"
assert_true "the init script writes the API key into the dependencyCheck extension" \
  "grep -q 'extension.nvd.apiKey = apiKey' '$INIT_GRADLE'"
assert_true "the init script writes the data directory into the dependencyCheck extension" \
  "grep -q 'extension.data.directory = dataDirectory' '$INIT_GRADLE'"
assert_true "the init script applies after evaluation so it beats the project's own config" \
  "grep -q 'projectsEvaluated' '$INIT_GRADLE'"

# =============================================================================
# Test 6: the dead configuration knobs are gone from every platform
# =============================================================================
echo "TEST 6: no platform relies on configuration the plugins ignore"
cd "$SCRIPTS_DIR"
# OWASP_PATH was never read by anything; the Gradle plugin has no such setting.
assert_true "OWASP_PATH is gone repo-wide" \
  "! grep -rq 'OWASP_PATH' .github/workflows github gitlab azure-devops global"
# Setting -DdataDirectory through MAVEN_OPTS relied on Maven's system-property fallback; the mojo has
# a real user property for it.
assert_true "MAVEN_OPTS is no longer used to smuggle -DdataDirectory" \
  "! grep -rq 'MAVEN_OPTS.*dataDirectory' .github/workflows gitlab azure-devops"
# The one remaining bare `env: NVD_API_KEY` is the Azure step, which run.sh reads deliberately; no
# platform may hand it to a plugin and assume it lands.
assert_true "no workflow calls a dependency-check plugin directly any more" \
  "! grep -rqE 'mvn .*dependency-check|gradlew? dependencyCheckAnalyze' .github/workflows gitlab azure-devops"

# =============================================================================
# Test 7: the GitHub cache survives the failure that used to empty it
# =============================================================================
echo "TEST 7: the GitHub NVD cache is written even when the job dies"
# The old job used the all-in-one actions/cache, whose save runs in a post-job step that is skipped on
# cancellation. The 5h45m run was cancelled, so nothing was ever cached, so the next run started cold
# again -- the loop this splits apart.
assert_true "restores with actions/cache/restore" \
  "grep -q 'actions/cache/restore@v4' '$ACTION'"
assert_true "saves with an explicit actions/cache/save step" \
  "grep -q 'actions/cache/save@v4' '$ACTION'"
assert_true "saves under always(), so a cancelled or failed run still keeps its progress" \
  "grep -qE \"if: \\\"always\\(\\) && steps.restore_nvd.outputs.cache-hit\" '$ACTION'"
assert_true "does not use the all-in-one actions/cache, whose save is skipped on cancellation" \
  "! grep -qE 'uses: .actions/cache@' '$ACTION'"
assert_true "keys the cache daily so the snapshot cannot go stale forever" \
  "grep -q 'steps.date.outputs.date' '$ACTION'"
assert_true "falls back to the most recent snapshot via restore-keys" \
  "grep -q 'restore-keys' '$ACTION'"
assert_true "checks out before restoring, so checkout cannot clean the restored database away" \
  "[ \$(grep -n 'actions/checkout' '$ACTION' | cut -d: -f1) -lt \$(grep -n 'actions/cache/restore' '$ACTION' | cut -d: -f1) ]"

# =============================================================================
# Test 8: every platform caps the job, so a runaway download cannot burn minutes
# =============================================================================
echo "TEST 8: every platform bounds the job's runtime"
assert_true "GitHub Actions: maven workflow has a timeout" \
  "grep -q 'timeout-minutes: 30' .github/workflows/maven.yaml"
assert_true "GitHub Actions: gradle workflow has a timeout" \
  "grep -q 'timeout-minutes: 30' .github/workflows/gradle.yaml"
assert_true "GitLab CI: maven job has a timeout" \
  "grep -q \"timeout: '30 minutes'\" gitlab/java/stages/20-security/maven.yaml"
assert_true "GitLab CI: gradle job has a timeout" \
  "grep -q \"timeout: '30 minutes'\" gitlab/java/stages/20-security/gradle.yaml"
assert_true "Azure DevOps: dependency-check job has a timeout" \
  "grep -q 'timeoutInMinutes: 30' azure-devops/java/stages/20-security/java.yaml"

# =============================================================================
# Test 9: all three platforms run the same script
# =============================================================================
echo "TEST 9: all three platforms share one runner"
assert_true "run.sh is executable" "[ -x '$RUN_SH' ]"
assert_true "GitHub Actions calls the shared runner" \
  "grep -q 'global/scripts/languages/java/dependency-check/run.sh' '$ACTION'"
assert_true "GitLab CI (maven) calls the shared runner" \
  "grep -q 'global/scripts/languages/java/dependency-check/run.sh' gitlab/java/stages/20-security/maven.yaml"
assert_true "GitLab CI (gradle) calls the shared runner" \
  "grep -q 'global/scripts/languages/java/dependency-check/run.sh' gitlab/java/stages/20-security/gradle.yaml"
assert_true "Azure DevOps calls the shared runner" \
  "grep -q 'global/scripts/languages/java/dependency-check/run.sh' azure-devops/java/stages/20-security/java.yaml"

# =============================================================================
echo
echo "================================"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
  echo "================================"
  exit 1
fi
echo "Tests failed: 0"
echo "================================"
echo -e "${GREEN}All dependency-check tests passed!${NC}"
