#!/usr/bin/env bash
# Validation script for SonarQube auto-derivation of projectKey and projectName
# Tests the normalize_sonar_key function and auto-derivation logic in
# global/scripts/tools/sonarqube/run.sh, plus the test-classification defaults
# and the first-party acceptance of `githubactions:S7637` findings.

set -euo pipefail

echo "=== Testing SonarQube Auto-Derivation Logic ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SONAR_SCRIPT="$SCRIPT_DIR/../../global/scripts/tools/sonarqube/run.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
  local result=$1
  local message=$2
  if [ "$result" -eq 0 ]; then
    echo -e "${GREEN}  PASS: $message${NC}"
    ((TESTS_PASSED++)) || true
  else
    echo -e "${RED}  FAIL: $message${NC}"
    ((TESTS_FAILED++)) || true
  fi
}

TEST_DIR="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# Extract the normalize_sonar_key function from run.sh for isolated testing
eval "$(sed -n '/^normalize_sonar_key()/,/^}/p' "$SONAR_SCRIPT")"

# CI platform variables that must be scrubbed between tests to prevent the
# runner's own environment (e.g. GITHUB_REPOSITORY on GitHub Actions) from
# leaking into the derivation logic.
CI_VARS="GITHUB_REPOSITORY SYSTEM_TEAMPROJECT BUILD_REPOSITORY_NAME CI_PROJECT_PATH CI_PROJECT_NAME SONAR_PROJECT_KEY SONAR_PROJECT_NAME SONAR_FIRST_PARTY_OWNERS"

# Optional directory whose contents are copied into the work directory before
# the script runs: the `.github/workflows` fixtures of the S7637 tests. Set it
# through run_with_fixtures rather than by hand.
FIXTURES_DIR=""

# Run the auto-derivation logic in an isolated subshell with a clean environment.
# Usage: props=$(run_derivation [starter-properties-file] [-- VAR1=val1 VAR2=val2 ...])
# All CI_VARS are unset, then only the explicitly passed VAR=val pairs are exported.
# The script's output lands in run.log next to the returned properties file.
run_derivation() {
  local workdir
  workdir="$(mktemp -d "$TEST_DIR/workdir-XXXXXX")" || exit 1

  # Parse arguments: optional properties file, then optional -- VAR=val pairs
  local props_file=""
  local -a env_pairs=()
  local past_separator=false
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then
      past_separator=true
      continue
    fi
    if $past_separator; then
      env_pairs+=("$arg")
    else
      props_file="$arg"
    fi
  done

  # Copy a starter properties file if provided, otherwise create empty
  if [ -n "$props_file" ] && [ -f "$props_file" ]; then
    cp "$props_file" "$workdir/sonar-project.properties"
  else
    touch "$workdir/sonar-project.properties"
  fi

  # Copy the workflow fixtures, when a test provides them
  if [ -n "$FIXTURES_DIR" ]; then
    cp -R "$FIXTURES_DIR/." "$workdir/"
  fi

  # Write env pairs to a sidecar file for the subshell to source after scrubbing
  local envfile="$workdir/.test-env"
  : > "$envfile"
  for pair in "${env_pairs[@]+"${env_pairs[@]}"}"; do
    local var="${pair%%=*}"
    local val="${pair#*=}"
    printf 'export %s='\''%s'\''\n' "$var" "$val" >> "$envfile"
  done

  # Initialize a git repo so `git describe` doesn't fail fatally
  (
    cd "$workdir" || exit 1
    git init -q
    git config user.email 'test@test.com'
    git config user.name 'test'
    git commit --allow-empty -m 'init' -q
  )

  # Run the script in a subshell with a scrubbed environment
  (
    cd "$workdir" || exit 1

    # Scrub all CI platform variables
    for v in $CI_VARS; do
      unset "$v" 2>/dev/null || true
    done

    # Apply only the caller-specified variables
    # shellcheck disable=SC1091
    . "$workdir/.test-env"

    # Override sonar-scanner to no-op
    export PATH="$workdir/bin:$PATH"
    mkdir -p "$workdir/bin"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$workdir/bin/sonar-scanner"
    chmod +x "$workdir/bin/sonar-scanner"

    # `SONAR_SCRIPT` is built from `SCRIPT_DIR` at the top of this file, so the target IS
    # knowable -- it is just not a literal. `source-path=SCRIPTDIR` makes the directive
    # resolve the same way the assignment does, from this script's own directory, so it
    # holds whatever working directory ShellCheck is invoked from.
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=../../global/scripts/tools/sonarqube/run.sh
    . "$SONAR_SCRIPT"
  ) > "$workdir/run.log" 2>&1

  echo "$workdir/sonar-project.properties"
}

# Same as run_derivation, with the first argument naming a fixture directory
# copied into the work directory before the script runs.
# Usage: props=$(run_with_fixtures fixture-dir [starter-properties-file] [-- VAR=val ...])
run_with_fixtures() {
  local fixtures=$1
  shift
  FIXTURES_DIR="$fixtures" run_derivation "$@"
}

# Print the path of the log written by the run that produced a properties file.
run_log() {
  echo "$(dirname "$1")/run.log"
}

# Create an empty fixture tree with a `.github/workflows` directory and print its path.
make_fixtures() {
  local dir
  dir="$(mktemp -d "$TEST_DIR/fixtures-XXXXXX")" || exit 1
  mkdir -p "$dir/.github/workflows"
  echo "$dir"
}

# Number of lines defining exactly the given key (`key=`), as the scanner reads them.
count_key() {
  grep -c "^$(printf '%s' "$1" | sed 's/\./\\./g')=" "$2" || true
}

# The values run.sh derives when sonar-project.properties classifies nothing.
TEST_PATTERNS='**/*_test.go,**/test/**,**/tests/**,**/test_*.py,**/*_test.py,**/conftest.py,**/*.test.ts,**/*.test.tsx,**/*.spec.ts,**/*.spec.tsx,**/*.test.js,**/*.spec.js,**/__tests__/**,**/src/test/**,**/*Tests/**,**/*.Tests/**,**/spec/**'
GENERATED_PATTERNS='**/vendor/**,**/node_modules/**,**/build/**,**/dist/**,**/coverage/**,**/.pipelines/**'

# A consumer workflow as the 17 rios0rios0 repositories ship it: a job-level
# reusable workflow and a step-level composite action, both floating on `main`,
# in the two quoting styles the repositories use.
FIRST_PARTY_WORKFLOW=$(cat <<'EOF'
name: 'default'
on:
  push:
    branches: [ 'main' ]
jobs:
  default:
    uses: 'rios0rios0/pipelines/.github/workflows/go-binary.yaml@main'
    secrets: inherit
  scripts:
    runs-on: 'ubuntu-latest'
    steps:
      - uses: rios0rios0/pipelines/github/global/abstracts/scripts-repo@main
EOF
)

# =============================================================================
# Test 1: normalize_sonar_key replaces '/' with '_'
# =============================================================================
echo "TEST 1: normalize_sonar_key — slashes replaced"
result=$(normalize_sonar_key "owner/repo")
print_result "$([ "$result" = "owner_repo" ] && echo 0 || echo 1)" \
  "owner/repo -> '$result' (expected 'owner_repo')"

# =============================================================================
# Test 2: normalize_sonar_key replaces spaces with '_'
# =============================================================================
echo "TEST 2: normalize_sonar_key — spaces replaced"
result=$(normalize_sonar_key "my project name")
print_result "$([ "$result" = "my_project_name" ] && echo 0 || echo 1)" \
  "my project name -> '$result' (expected 'my_project_name')"

# =============================================================================
# Test 3: normalize_sonar_key replaces unsupported characters
# =============================================================================
echo "TEST 3: normalize_sonar_key — unsupported chars replaced"
result=$(normalize_sonar_key "org/repo@feature#1")
print_result "$([ "$result" = "org_repo_feature_1" ] && echo 0 || echo 1)" \
  "org/repo@feature#1 -> '$result' (expected 'org_repo_feature_1')"

# =============================================================================
# Test 4: normalize_sonar_key preserves allowed characters
# =============================================================================
echo "TEST 4: normalize_sonar_key — allowed chars preserved"
result=$(normalize_sonar_key "my-project_v1.0:key")
print_result "$([ "$result" = "my-project_v1.0:key" ] && echo 0 || echo 1)" \
  "my-project_v1.0:key -> '$result' (expected 'my-project_v1.0:key')"

# =============================================================================
# Test 5: Existing sonar.projectKey is NOT overwritten
# =============================================================================
echo "TEST 5: Existing projectKey preserved"
cat > "$TEST_DIR/existing-key.properties" << 'EOF'
sonar.projectKey=my-existing-key
EOF
props=$(run_derivation "$TEST_DIR/existing-key.properties" -- GITHUB_REPOSITORY=owner/repo)
if grep -q 'sonar.projectKey=my-existing-key' "$props" && \
   [ "$(grep -c 'sonar.projectKey=' "$props")" -eq 1 ]; then
  print_result 0 "existing projectKey not overwritten"
else
  print_result 1 "existing projectKey was overwritten or duplicated"
fi

# =============================================================================
# Test 6: Existing sonar.projectName is NOT overwritten
# =============================================================================
echo "TEST 6: Existing projectName preserved"
cat > "$TEST_DIR/existing-name.properties" << 'EOF'
sonar.projectName=My Existing Name
EOF
props=$(run_derivation "$TEST_DIR/existing-name.properties" -- GITHUB_REPOSITORY=owner/repo)
if grep -q 'sonar.projectName=My Existing Name' "$props" && \
   [ "$(grep -c 'sonar.projectName=' "$props")" -eq 1 ]; then
  print_result 0 "existing projectName not overwritten"
else
  print_result 1 "existing projectName was overwritten or duplicated"
fi

# =============================================================================
# Test 7: SONAR_PROJECT_KEY env var override
# =============================================================================
echo "TEST 7: SONAR_PROJECT_KEY env var override"
props=$(run_derivation -- SONAR_PROJECT_KEY=custom-key GITHUB_REPOSITORY=owner/repo)
if grep -q 'sonar.projectKey=custom-key' "$props"; then
  print_result 0 "SONAR_PROJECT_KEY override used"
else
  print_result 1 "SONAR_PROJECT_KEY override not used"
fi

# =============================================================================
# Test 8: SONAR_PROJECT_NAME env var override
# =============================================================================
echo "TEST 8: SONAR_PROJECT_NAME env var override"
props=$(run_derivation -- "SONAR_PROJECT_NAME=Custom Name" GITHUB_REPOSITORY=owner/repo)
if grep -q 'sonar.projectName=Custom Name' "$props"; then
  print_result 0 "SONAR_PROJECT_NAME override used"
else
  print_result 1 "SONAR_PROJECT_NAME override not used"
fi

# =============================================================================
# Test 9: GitHub — derives key from GITHUB_REPOSITORY
# =============================================================================
echo "TEST 9: GitHub — projectKey from GITHUB_REPOSITORY"
props=$(run_derivation -- GITHUB_REPOSITORY=myorg/my-repo)
if grep -q 'sonar.projectKey=myorg_my-repo' "$props"; then
  print_result 0 "GitHub projectKey derived correctly"
else
  print_result 1 "GitHub projectKey derivation failed (contents: $(grep 'sonar.projectKey' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 10: GitHub — derives name from GITHUB_REPOSITORY
# =============================================================================
echo "TEST 10: GitHub — projectName from GITHUB_REPOSITORY"
props=$(run_derivation -- GITHUB_REPOSITORY=myorg/my-repo)
if grep -q 'sonar.projectName=my-repo' "$props"; then
  print_result 0 "GitHub projectName derived correctly"
else
  print_result 1 "GitHub projectName derivation failed (contents: $(grep 'sonar.projectName' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 11: Azure DevOps — derives key from SYSTEM_TEAMPROJECT + BUILD_REPOSITORY_NAME
# =============================================================================
echo "TEST 11: Azure DevOps — projectKey from SYSTEM_TEAMPROJECT + BUILD_REPOSITORY_NAME"
props=$(run_derivation -- SYSTEM_TEAMPROJECT=MyProject BUILD_REPOSITORY_NAME=my-repo)
if grep -q 'sonar.projectKey=MyProject_my-repo' "$props"; then
  print_result 0 "Azure DevOps projectKey derived correctly"
else
  print_result 1 "Azure DevOps projectKey derivation failed (contents: $(grep 'sonar.projectKey' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 12: Azure DevOps — derives name from SYSTEM_TEAMPROJECT/BUILD_REPOSITORY_NAME
# =============================================================================
echo "TEST 12: Azure DevOps — projectName from SYSTEM_TEAMPROJECT/BUILD_REPOSITORY_NAME"
props=$(run_derivation -- SYSTEM_TEAMPROJECT=MyProject BUILD_REPOSITORY_NAME=my-repo)
if grep -q 'sonar.projectName=MyProject/my-repo' "$props"; then
  print_result 0 "Azure DevOps projectName derived correctly"
else
  print_result 1 "Azure DevOps projectName derivation failed (contents: $(grep 'sonar.projectName' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 13: GitLab — derives key from CI_PROJECT_PATH
# =============================================================================
echo "TEST 13: GitLab — projectKey from CI_PROJECT_PATH"
props=$(run_derivation -- CI_PROJECT_PATH=group/subgroup/my-repo CI_PROJECT_NAME=my-repo)
if grep -q 'sonar.projectKey=group_subgroup_my-repo' "$props"; then
  print_result 0 "GitLab projectKey derived correctly"
else
  print_result 1 "GitLab projectKey derivation failed (contents: $(grep 'sonar.projectKey' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 14: GitLab — derives name from CI_PROJECT_NAME
# =============================================================================
echo "TEST 14: GitLab — projectName from CI_PROJECT_NAME"
props=$(run_derivation -- CI_PROJECT_PATH=group/subgroup/my-repo CI_PROJECT_NAME=my-repo)
if grep -q 'sonar.projectName=my-repo' "$props"; then
  print_result 0 "GitLab projectName derived correctly"
else
  print_result 1 "GitLab projectName derivation failed (contents: $(grep 'sonar.projectName' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 15: No CI variables — no derivation
# =============================================================================
echo "TEST 15: No CI variables — no derivation"
props=$(run_derivation)
if ! grep -q 'sonar.projectKey=' "$props" && ! grep -q 'sonar.projectName=' "$props"; then
  print_result 0 "no derivation when no CI variables set"
else
  print_result 1 "unexpected derivation occurred without CI variables"
fi

# =============================================================================
# Test 16: Test classification — defaults derived when the file has none
# =============================================================================
echo "TEST 16: Test classification — defaults derived when absent"
props=$(run_derivation -- GITHUB_REPOSITORY=owner/repo)
if grep -Fxq 'sonar.sources=.' "$props" && \
   grep -Fxq 'sonar.tests=.' "$props" && \
   grep -Fxq "sonar.test.inclusions=$TEST_PATTERNS" "$props" && \
   grep -Fxq "sonar.exclusions=$TEST_PATTERNS,$GENERATED_PATTERNS" "$props" && \
   grep -Fxq 'sonar.test.exclusions=**/vendor/**,**/node_modules/**' "$props"; then
  print_result 0 "sources, tests, test.inclusions, exclusions and test.exclusions derived"
else
  print_result 1 "test classification defaults missing or wrong (contents: $(grep -E 'sonar\.(sources|tests|test\.inclusions|exclusions|test\.exclusions)=' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 17: Test classification — repository values are NOT overridden
# =============================================================================
echo "TEST 17: Test classification — existing keys preserved"
cat > "$TEST_DIR/existing-scope.properties" << 'EOF'
sonar.sources=src
sonar.tests=qa
sonar.test.inclusions=qa/**/*_spec.rb
sonar.exclusions=src/generated/**
sonar.test.exclusions=qa/fixtures/**
EOF
props=$(run_derivation "$TEST_DIR/existing-scope.properties" -- GITHUB_REPOSITORY=owner/repo)
if grep -Fxq 'sonar.sources=src' "$props" && [ "$(count_key sonar.sources "$props")" -eq 1 ] && \
   grep -Fxq 'sonar.tests=qa' "$props" && [ "$(count_key sonar.tests "$props")" -eq 1 ] && \
   grep -Fxq 'sonar.test.inclusions=qa/**/*_spec.rb' "$props" && [ "$(count_key sonar.test.inclusions "$props")" -eq 1 ] && \
   grep -Fxq 'sonar.exclusions=src/generated/**' "$props" && [ "$(count_key sonar.exclusions "$props")" -eq 1 ] && \
   grep -Fxq 'sonar.test.exclusions=qa/fixtures/**' "$props" && [ "$(count_key sonar.test.exclusions "$props")" -eq 1 ]; then
  print_result 0 "repository-defined classification kept, nothing duplicated"
else
  print_result 1 "repository-defined classification overwritten or duplicated (contents: $(grep -E 'sonar\.(sources|tests|test\.inclusions|exclusions|test\.exclusions)=' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 18: Test classification — a repository-defined sonar.tests derives no
# other classification key. `sonar.sources=.` plus a `sonar.exclusions` that
# does not cover `qa/**` would make every file under `qa/` main AND test, and
# sonar-scanner aborts on that with "can't be indexed twice".
# =============================================================================
echo "TEST 18: Test classification — sonar.tests alone owns the whole partition"
cat > "$TEST_DIR/existing-tests.properties" << 'EOF'
sonar.tests=qa
EOF
props=$(run_derivation "$TEST_DIR/existing-tests.properties" -- GITHUB_REPOSITORY=owner/repo)
if grep -Fxq 'sonar.tests=qa' "$props" && [ "$(count_key sonar.tests "$props")" -eq 1 ] && \
   [ "$(count_key sonar.test.inclusions "$props")" -eq 0 ] && \
   [ "$(count_key sonar.sources "$props")" -eq 0 ] && \
   [ "$(count_key sonar.exclusions "$props")" -eq 0 ]; then
  print_result 0 "nothing derived against a repository-defined sonar.tests, so the main and test sets cannot overlap"
else
  print_result 1 "classification keys derived against a repository-defined sonar.tests (contents: $(grep -E 'sonar\.(sources|tests|test\.inclusions|exclusions)=' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 19: S7637 — a file with only first-party references is accepted
# =============================================================================
echo "TEST 19: S7637 — first-party workflow accepted"
fx=$(make_fixtures)
printf '%s\n' "$FIRST_PARTY_WORKFLOW" > "$fx/.github/workflows/default.yaml"
props=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=rios0rios0/my-repo)
if grep -Fxq 'sonar.issue.ignore.multicriteria.fp1.ruleKey=githubactions:S7637' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria.fp1.resourceKey=.github/workflows/default.yaml' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria=fp1' "$props" && \
   grep -q 'Accepting .github/workflows/default.yaml for githubactions:S7637: all 2 uses: references' "$(run_log "$props")"; then
  print_result 0 "fp1 ignore rule written for .github/workflows/default.yaml and logged with its reason"
else
  print_result 1 "first-party workflow not accepted (contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'missing'); log: $(grep 'S7637' "$(run_log "$props")" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 20: S7637 — one unpinned third-party action rejects the whole file
# =============================================================================
echo "TEST 20: S7637 — unpinned third-party action rejected"
fx=$(make_fixtures)
{
  printf '%s\n' "$FIRST_PARTY_WORKFLOW"
  printf '      - uses: actions/checkout@v4\n'
} > "$fx/.github/workflows/default.yaml"
props=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=rios0rios0/my-repo)
if ! grep -q 'sonar.issue.ignore.multicriteria' "$props" && \
   grep -q "Keeping githubactions:S7637 findings in .github/workflows/default.yaml: 'actions/checkout@v4' is neither first-party, local nor pinned to a commit SHA" "$(run_log "$props")"; then
  print_result 0 "no ignore rule written; the log names actions/checkout@v4 as the blocker"
else
  print_result 1 "file with an unpinned third-party action was accepted (contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'none'); log: $(grep 'S7637' "$(run_log "$props")" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 21: S7637 — SHA-pinned third-party and local references are accepted
# =============================================================================
echo "TEST 21: S7637 — SHA-pinned third-party action accepted"
fx=$(make_fixtures)
{
  printf '%s\n' "$FIRST_PARTY_WORKFLOW"
  printf '      - name: %s\n' "'Checkout'"
  printf '        uses: "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803" # v6.1.0\n'
  printf '      - uses: ./.github/actions/local-thing\n'
} > "$fx/.github/workflows/default.yaml"
props=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=rios0rios0/my-repo)
if grep -Fxq 'sonar.issue.ignore.multicriteria.fp1.resourceKey=.github/workflows/default.yaml' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria=fp1' "$props" && \
   grep -q 'Accepting .github/workflows/default.yaml for githubactions:S7637: all 4 uses: references' "$(run_log "$props")"; then
  print_result 0 "quoted, commented SHA pin and local action accepted alongside first-party references"
else
  print_result 1 "SHA-pinned third-party action rejected (contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'none'); log: $(grep 'S7637' "$(run_log "$props")" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 22: S7637 — merged with the multicriteria list the repository defines
# =============================================================================
echo "TEST 22: S7637 — existing multicriteria list merged"
cat > "$TEST_DIR/existing-ignores.properties" << 'EOF'
sonar.issue.ignore.multicriteria=e1
sonar.issue.ignore.multicriteria.e1.ruleKey=go:S1192
sonar.issue.ignore.multicriteria.e1.resourceKey=**/*.go
EOF
fx=$(make_fixtures)
printf '%s\n' "$FIRST_PARTY_WORKFLOW" > "$fx/.github/workflows/default.yaml"
props=$(run_with_fixtures "$fx" "$TEST_DIR/existing-ignores.properties" -- GITHUB_REPOSITORY=rios0rios0/my-repo)
if [ "$(count_key sonar.issue.ignore.multicriteria "$props")" -eq 1 ] && \
   grep -Fxq 'sonar.issue.ignore.multicriteria=e1,fp1' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria.e1.ruleKey=go:S1192' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria.e1.resourceKey=**/*.go' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria.fp1.ruleKey=githubactions:S7637' "$props"; then
  print_result 0 "single list line reads e1,fp1 and the e1 entries survive"
else
  print_result 1 "multicriteria list not merged (contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 23: S7637 — no owner known, nothing ignored
# =============================================================================
echo "TEST 23: S7637 — no-op without an owner"
fx=$(make_fixtures)
printf '%s\n' "$FIRST_PARTY_WORKFLOW" > "$fx/.github/workflows/default.yaml"
props=$(run_with_fixtures "$fx")
if ! grep -q 'sonar.issue.ignore.multicriteria' "$props" && \
   grep -q 'No first-party owner known' "$(run_log "$props")"; then
  print_result 0 "no ignore rule without SONAR_FIRST_PARTY_OWNERS or GITHUB_REPOSITORY"
else
  print_result 1 "ignore rule written without a known owner (contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 24: S7637 — SONAR_FIRST_PARTY_OWNERS overrides the GITHUB_REPOSITORY owner
# =============================================================================
echo "TEST 24: S7637 — SONAR_FIRST_PARTY_OWNERS override"
fx=$(make_fixtures)
cat > "$fx/.github/workflows/default.yaml" << 'EOF'
jobs:
  default:
    uses: acme/pipelines/.github/workflows/go.yaml@main
EOF
props=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=other/repo)
control_rejected=$(! grep -q 'sonar.issue.ignore.multicriteria' "$props" && echo yes || echo no)
props=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=other/repo "SONAR_FIRST_PARTY_OWNERS=Acme, rios0rios0")
if [ "$control_rejected" = "yes" ] && \
   grep -Fxq 'sonar.issue.ignore.multicriteria.fp1.resourceKey=.github/workflows/default.yaml' "$props" && \
   grep -q 'Trusting first-party owners for githubactions:S7637: Acme, rios0rios0' "$(run_log "$props")"; then
  print_result 0 "acme/... rejected under owner 'other', accepted once SONAR_FIRST_PARTY_OWNERS lists Acme (case-insensitively)"
else
  print_result 1 "SONAR_FIRST_PARTY_OWNERS not honoured (control rejected: $control_rejected; contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 25: S7637 — per-file decisions across workflows and composite actions
# =============================================================================
echo "TEST 25: S7637 — mixed files judged one by one"
fx=$(make_fixtures)
mkdir -p "$fx/.github/actions/setup"
printf '%s\n' "$FIRST_PARTY_WORKFLOW" > "$fx/.github/workflows/default.yaml"
cat > "$fx/.github/workflows/release.yml" << 'EOF'
jobs:
  release:
    uses: rios0rios0/pipelines/.github/workflows/release.yaml@main
  publish:
    steps:
      - uses: actions/setup-go@v5
EOF
cat > "$fx/.github/actions/setup/action.yaml" << 'EOF'
runs:
  using: composite
  steps:
    - uses: rios0rios0/pipelines/github/global/abstracts/scripts-repo@main
EOF
printf 'name: no-uses\non: push\n' > "$fx/.github/workflows/empty.yaml"
props=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=rios0rios0/my-repo)
if grep -Fxq 'sonar.issue.ignore.multicriteria.fp1.resourceKey=.github/actions/setup/action.yaml' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria.fp2.resourceKey=.github/workflows/default.yaml' "$props" && \
   ! grep -q 'resourceKey=.github/workflows/release.yml' "$props" && \
   ! grep -q 'resourceKey=.github/workflows/empty.yaml' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria=fp1,fp2' "$props" && \
   grep -q "Keeping githubactions:S7637 findings in .github/workflows/release.yml: 'actions/setup-go@v5'" "$(run_log "$props")"; then
  print_result 0 "composite action and clean workflow accepted; the workflow with actions/setup-go@v5 kept its findings"
else
  print_result 1 "per-file decision wrong (contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'none'); log: $(grep 'S7637' "$(run_log "$props")" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 26: S7637 — ids never collide with the repository's own
# =============================================================================
echo "TEST 26: S7637 — id collision avoided"
cat > "$TEST_DIR/existing-fp1.properties" << 'EOF'
sonar.issue.ignore.multicriteria = fp1
sonar.issue.ignore.multicriteria.fp1.ruleKey=go:S1192
sonar.issue.ignore.multicriteria.fp1.resourceKey=**/*.go
EOF
fx=$(make_fixtures)
printf '%s\n' "$FIRST_PARTY_WORKFLOW" > "$fx/.github/workflows/default.yaml"
props=$(run_with_fixtures "$fx" "$TEST_DIR/existing-fp1.properties" -- GITHUB_REPOSITORY=rios0rios0/my-repo)
if grep -Fxq 'sonar.issue.ignore.multicriteria.fp1.ruleKey=go:S1192' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria.fp2.ruleKey=githubactions:S7637' "$props" && \
   grep -Fxq 'sonar.issue.ignore.multicriteria=fp1,fp2' "$props" && \
   [ "$(count_key sonar.issue.ignore.multicriteria "$props")" -eq 1 ]; then
  print_result 0 "repository's fp1 kept, the derived rule became fp2, list normalized to fp1,fp2"
else
  print_result 1 "id collision or list not normalized (contents: $(grep 'multicriteria' "$props" 2>/dev/null || echo 'none'))"
fi

# =============================================================================
# Test 27: Test classification — a lone sonar.exclusions derives no test set
# Deriving `sonar.tests=.` next to a repository `sonar.exclusions` that excludes
# no test pattern makes every `*_test.go` main AND test, and sonar-scanner
# aborts on that with "can't be indexed twice" — the same failure TEST 18
# guards from the other half of the partition.
# =============================================================================
echo "TEST 27: Test classification — sonar.exclusions alone derives no test set"
cat > "$TEST_DIR/existing-exclusions.properties" << 'EOF'
sonar.exclusions=src/generated/**
EOF
props=$(run_derivation "$TEST_DIR/existing-exclusions.properties" -- GITHUB_REPOSITORY=owner/repo)
if grep -Fxq 'sonar.exclusions=src/generated/**' "$props" && [ "$(count_key sonar.exclusions "$props")" -eq 1 ] && \
   [ "$(count_key sonar.tests "$props")" -eq 0 ] && \
   [ "$(count_key sonar.sources "$props")" -eq 0 ] && \
   [ "$(count_key sonar.test.inclusions "$props")" -eq 0 ] && \
   grep -q 'Keeping the test classification from sonar-project.properties' "$(run_log "$props")"; then
  print_result 0 "repository sonar.exclusions kept and no test set derived against it"
else
  print_result 1 "test set derived against a lone repository sonar.exclusions (contents: $(grep -E 'sonar\.(sources|tests|test\.inclusions|exclusions)=' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 28: Test classification — sonar.test.exclusions alone still derives the set
# It can only shrink the test set, so it cannot produce the overlap TEST 18 and
# TEST 27 guard, and must not cost the repository the derivation.
# =============================================================================
echo "TEST 28: Test classification — sonar.test.exclusions alone still derives the set"
cat > "$TEST_DIR/existing-test-exclusions.properties" << 'EOF'
sonar.test.exclusions=qa/fixtures/**
EOF
props=$(run_derivation "$TEST_DIR/existing-test-exclusions.properties" -- GITHUB_REPOSITORY=owner/repo)
if grep -Fxq 'sonar.test.exclusions=qa/fixtures/**' "$props" && [ "$(count_key sonar.test.exclusions "$props")" -eq 1 ] && \
   grep -Fxq 'sonar.sources=.' "$props" && \
   grep -Fxq 'sonar.tests=.' "$props" && \
   grep -Fxq "sonar.test.inclusions=$TEST_PATTERNS" "$props" && \
   grep -Fxq "sonar.exclusions=$TEST_PATTERNS,$GENERATED_PATTERNS" "$props"; then
  print_result 0 "the four classification keys derived; the repository's sonar.test.exclusions kept"
else
  print_result 1 "derivation skipped for a lone sonar.test.exclusions (contents: $(grep -E 'sonar\.(sources|tests|test\.inclusions|exclusions|test\.exclusions)=' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Coverage detection
#
# Everything above leaves the work directory without a single coverage file, so
# `COVERAGE_FOUND` is false in every one of those scenarios and the `else` branch
# holding the Go and JaCoCo derivations never runs. That gap is how two defects
# reached `main` in consecutive commits: first the detection globbed the
# workspace root only, so a project in a subfolder was read as having no coverage
# at all; then the fix for it joined the root and the project directory into one
# space-separated string and iterated it unquoted, so a `working_directory` of
# `my app` word-split back into two paths that do not exist.
#
# Both failures land in the SAME branch, and that branch does not skip -- it
# appends an EMPTY `sonar.javascript.lcov.reportPaths=` over whatever the
# repository declared, which a Java properties file resolves as the last
# definition winning. SonarQube then reports 0% coverage on new code and fails a
# default quality gate, from a job that is `continue-on-error` and stays green
# with one line of log. Nothing about that is visible without an assertion, which
# is why these four exist.
# =============================================================================

# An empty fixture tree to seed coverage files into, copied into the work
# directory before the script runs. `make_fixtures` is not reused because these
# tests must NOT create `.github/workflows`.
make_coverage_fixtures() {
  mktemp -d "$TEST_DIR/coverage-XXXXXX"
}

# The seven properties the "no coverage" branch clears, as it writes them.
CLEARED_COVERAGE_KEY='^sonar\.javascript\.lcov\.reportPaths=$'

echo "TEST 29: Coverage detection — a project directory containing a space"
fx=$(make_coverage_fixtures)
mkdir -p "$fx/my app/coverage"
: > "$fx/my app/coverage/lcov.info"
: > "$fx/my app/coverage.out"
printf 'sonar.javascript.lcov.reportPaths=my app/coverage/lcov.info\n' \
  > "$TEST_DIR/spaced-coverage.properties"
props=$(run_with_fixtures "$fx" "$TEST_DIR/spaced-coverage.properties" -- \
  GITHUB_REPOSITORY=owner/repo "SONAR_PROJECT_DIR=my app")
if ! grep -Eq "$CLEARED_COVERAGE_KEY" "$props" \
  && [ "$(count_key sonar.javascript.lcov.reportPaths "$props")" -eq 1 ] \
  && grep -Fxq 'sonar.go.coverage.reportPaths=my app/coverage.out' "$props"; then
  print_result 0 "a spaced SONAR_PROJECT_DIR keeps the repository's report path and derives the Go profile"
else
  print_result 1 "a spaced SONAR_PROJECT_DIR word-split back into the clearing branch (contents: $(grep -E 'sonar\.(javascript\.lcov|go\.coverage)' "$props" 2>/dev/null || echo 'missing'))"
fi

echo "TEST 30: Coverage detection — a project in a plain subfolder"
fx=$(make_coverage_fixtures)
mkdir -p "$fx/app/coverage"
: > "$fx/app/coverage/lcov.info"
printf 'sonar.javascript.lcov.reportPaths=app/coverage/lcov.info\n' \
  > "$TEST_DIR/subfolder-coverage.properties"
props=$(run_with_fixtures "$fx" "$TEST_DIR/subfolder-coverage.properties" -- \
  GITHUB_REPOSITORY=owner/repo SONAR_PROJECT_DIR=app)
if ! grep -Eq "$CLEARED_COVERAGE_KEY" "$props" \
  && [ "$(count_key sonar.javascript.lcov.reportPaths "$props")" -eq 1 ] \
  && ! grep -q 'No coverage files found' "$(run_log "$props")"; then
  print_result 0 "a subfolder project keeps the report path it declared"
else
  print_result 1 "a subfolder project had its report path cleared (contents: $(grep -E 'sonar\.javascript\.lcov' "$props" 2>/dev/null || echo 'missing'))"
fi

echo "TEST 31: Coverage detection — a root-only repository derives the same value three ways"
fx=$(make_coverage_fixtures)
: > "$fx/coverage.out"
root_unset=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=owner/repo)
root_dot=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=owner/repo SONAR_PROJECT_DIR=.)
root_missing=$(run_with_fixtures "$fx" -- GITHUB_REPOSITORY=owner/repo SONAR_PROJECT_DIR=nope)
if grep -Fxq 'sonar.go.coverage.reportPaths=coverage.out' "$root_unset" \
  && grep -Fxq 'sonar.go.coverage.reportPaths=coverage.out' "$root_dot" \
  && grep -Fxq 'sonar.go.coverage.reportPaths=coverage.out' "$root_missing"; then
  print_result 0 "SONAR_PROJECT_DIR unset, '.' and a missing directory all derive the root value unchanged"
else
  print_result 1 "the root derivation moved (unset: $(grep -E 'sonar\.go\.coverage' "$root_unset" 2>/dev/null || echo 'missing'), '.': $(grep -E 'sonar\.go\.coverage' "$root_dot" 2>/dev/null || echo 'missing'), missing: $(grep -E 'sonar\.go\.coverage' "$root_missing" 2>/dev/null || echo 'missing'))"
fi

echo "TEST 32: Coverage detection — an empty tree still clears the report paths"
fx=$(make_coverage_fixtures)
printf 'sonar.javascript.lcov.reportPaths=coverage/lcov.info\n' \
  > "$TEST_DIR/no-coverage.properties"
props=$(run_with_fixtures "$fx" "$TEST_DIR/no-coverage.properties" -- \
  GITHUB_REPOSITORY=owner/repo SONAR_PROJECT_DIR=app)
cleared_count=$(grep -cE '^sonar\.[A-Za-z.]+[Rr]eportsPaths=$|^sonar\.[A-Za-z.]+[Rr]eportPaths=$' "$props" || true)
if grep -Eq "$CLEARED_COVERAGE_KEY" "$props" \
  && [ "$cleared_count" -eq 7 ] \
  && grep -q 'No coverage files found' "$(run_log "$props")"; then
  print_result 0 "a tree with no coverage anywhere still clears the seven report-path properties"
else
  print_result 1 "the no-coverage branch stopped clearing ($cleared_count of 7 empty entries)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
