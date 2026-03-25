#!/usr/bin/env bash
# Validation script for SonarQube auto-derivation of projectKey and projectName
# Tests the normalize_sonar_key function and auto-derivation logic in
# global/scripts/tools/sonarqube/run.sh

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

TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# Extract the normalize_sonar_key function from run.sh for isolated testing
eval "$(sed -n '/^normalize_sonar_key()/,/^}/p' "$SONAR_SCRIPT")"

# Extract auto-derivation block (lines 11-45: projectKey + projectName logic)
# We run the derivation block in a subshell with controlled env vars and a temp
# sonar-project.properties file.
run_derivation() {
  # given
  local workdir="$TEST_DIR/workdir-$$-$RANDOM"
  mkdir -p "$workdir"

  # Copy a starter properties file if provided as $1, otherwise create empty
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    cp "$1" "$workdir/sonar-project.properties"
  else
    touch "$workdir/sonar-project.properties"
  fi

  # Initialize a git repo so `git describe` doesn't fail fatally
  (cd "$workdir" && git init -q && git commit --allow-empty -m 'init' -q)

  # when — run the entire script in a subshell, but replace sonar-scanner with true
  (
    cd "$workdir"
    # Override sonar-scanner to no-op
    sonar_scanner() { :; }
    alias sonar-scanner=true
    export PATH="$workdir/bin:$PATH"
    mkdir -p "$workdir/bin"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$workdir/bin/sonar-scanner"
    chmod +x "$workdir/bin/sonar-scanner"

    # Source the script (set -e is already active, the script uses set -e too)
    . "$SONAR_SCRIPT"
  ) > /dev/null 2>&1

  # then — return the properties file path for assertions
  echo "$workdir/sonar-project.properties"
}

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
props=$(GITHUB_REPOSITORY="owner/repo" run_derivation "$TEST_DIR/existing-key.properties")
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
props=$(GITHUB_REPOSITORY="owner/repo" run_derivation "$TEST_DIR/existing-name.properties")
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
props=$(SONAR_PROJECT_KEY="custom-key" GITHUB_REPOSITORY="owner/repo" run_derivation)
if grep -q 'sonar.projectKey=custom-key' "$props"; then
  print_result 0 "SONAR_PROJECT_KEY override used"
else
  print_result 1 "SONAR_PROJECT_KEY override not used"
fi

# =============================================================================
# Test 8: SONAR_PROJECT_NAME env var override
# =============================================================================
echo "TEST 8: SONAR_PROJECT_NAME env var override"
props=$(SONAR_PROJECT_NAME="Custom Name" GITHUB_REPOSITORY="owner/repo" run_derivation)
if grep -q 'sonar.projectName=Custom Name' "$props"; then
  print_result 0 "SONAR_PROJECT_NAME override used"
else
  print_result 1 "SONAR_PROJECT_NAME override not used"
fi

# =============================================================================
# Test 9: GitHub — derives key from GITHUB_REPOSITORY
# =============================================================================
echo "TEST 9: GitHub — projectKey from GITHUB_REPOSITORY"
props=$(GITHUB_REPOSITORY="myorg/my-repo" run_derivation)
if grep -q 'sonar.projectKey=myorg_my-repo' "$props"; then
  print_result 0 "GitHub projectKey derived correctly"
else
  print_result 1 "GitHub projectKey derivation failed (contents: $(grep 'sonar.projectKey' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 10: GitHub — derives name from GITHUB_REPOSITORY
# =============================================================================
echo "TEST 10: GitHub — projectName from GITHUB_REPOSITORY"
props=$(GITHUB_REPOSITORY="myorg/my-repo" run_derivation)
if grep -q 'sonar.projectName=my-repo' "$props"; then
  print_result 0 "GitHub projectName derived correctly"
else
  print_result 1 "GitHub projectName derivation failed (contents: $(grep 'sonar.projectName' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 11: Azure DevOps — derives key from SYSTEM_TEAMPROJECT + BUILD_REPOSITORY_NAME
# =============================================================================
echo "TEST 11: Azure DevOps — projectKey from SYSTEM_TEAMPROJECT + BUILD_REPOSITORY_NAME"
props=$(SYSTEM_TEAMPROJECT="MyProject" BUILD_REPOSITORY_NAME="my-repo" run_derivation)
if grep -q 'sonar.projectKey=MyProject_my-repo' "$props"; then
  print_result 0 "Azure DevOps projectKey derived correctly"
else
  print_result 1 "Azure DevOps projectKey derivation failed (contents: $(grep 'sonar.projectKey' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 12: Azure DevOps — derives name from BUILD_REPOSITORY_NAME
# =============================================================================
echo "TEST 12: Azure DevOps — projectName from BUILD_REPOSITORY_NAME"
props=$(SYSTEM_TEAMPROJECT="MyProject" BUILD_REPOSITORY_NAME="my-repo" run_derivation)
if grep -q 'sonar.projectName=my-repo' "$props"; then
  print_result 0 "Azure DevOps projectName derived correctly"
else
  print_result 1 "Azure DevOps projectName derivation failed (contents: $(grep 'sonar.projectName' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 13: GitLab — derives key from CI_PROJECT_PATH
# =============================================================================
echo "TEST 13: GitLab — projectKey from CI_PROJECT_PATH"
props=$(CI_PROJECT_PATH="group/subgroup/my-repo" CI_PROJECT_NAME="my-repo" run_derivation)
if grep -q 'sonar.projectKey=group_subgroup_my-repo' "$props"; then
  print_result 0 "GitLab projectKey derived correctly"
else
  print_result 1 "GitLab projectKey derivation failed (contents: $(grep 'sonar.projectKey' "$props" 2>/dev/null || echo 'missing'))"
fi

# =============================================================================
# Test 14: GitLab — derives name from CI_PROJECT_NAME
# =============================================================================
echo "TEST 14: GitLab — projectName from CI_PROJECT_NAME"
props=$(CI_PROJECT_PATH="group/subgroup/my-repo" CI_PROJECT_NAME="my-repo" run_derivation)
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
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
