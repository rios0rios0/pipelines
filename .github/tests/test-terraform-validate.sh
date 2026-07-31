#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016  # *_OUT/*_RC vars and the single-quoted condition
# strings are consumed inside assert_true's eval, which shellcheck cannot follow
set -e

# Test script for the Terraform validate tier.
# Exercises validate/run.sh against synthetic root modules and asserts:
#   * a valid root module passes and is reported as a JUnit testcase
#   * an undeclared reference fails, and the diagnostic reaches the report
#   * the no-op contract holds when the configured roots are absent
#   * XML metacharacters in a path or a diagnostic cannot break the report
#
# Uses only the `null` provider so the tests need one small download rather
# than a cloud provider, and no credentials of any kind.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/terraform/validate/run.sh"
TEST_DIR="$(mktemp -d)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

if ! command -v terraform > /dev/null 2>&1; then
  echo -e "${YELLOW}SKIP: terraform not on PATH; the validate tier cannot be exercised.${NC}"
  exit 0
fi

# A root module that is valid: declares the provider it uses and references
# only identifiers that exist.
make_valid_root() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/main.tf" << 'EOF'
terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

resource "null_resource" "example" {}

output "example_id" {
  value = null_resource.example.id
}
EOF
}

# A root module that PARSES as valid HCL but references a resource that was
# never declared -- the class of defect no parser-based tier can see.
make_undeclared_reference_root() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/main.tf" << 'EOF'
terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

resource "null_resource" "example" {}

output "example_id" {
  value = null_resource.deleted_by_a_rename.id
}
EOF
}

run_validate() {
  local repo="$1"
  shift
  (cd "$repo" && REPORT_PATH="build/reports" "$@" "$RUN_SH")
}

echo "== a valid root module passes =="
VALID_REPO="$TEST_DIR/valid"
make_valid_root "$VALID_REPO/stacks/app"
VALID_RC=0
VALID_OUT="$(run_validate "$VALID_REPO" 2>&1)" || VALID_RC=$?
VALID_JUNIT="$VALID_REPO/build/reports/junit-validate.xml"

assert_true "exits 0" "[ $VALID_RC -eq 0 ]"
assert_true "reports one root module" '[[ "$VALID_OUT" == *"Validated 1 root module"* ]]'
assert_true "reports zero failures" '[[ "$VALID_OUT" == *"1 passed, 0 failed"* ]]'
assert_true "writes the JUnit report" "[ -f '$VALID_JUNIT' ]"
assert_true "JUnit names the directory" "grep -q 'stacks/app' '$VALID_JUNIT'"
assert_true "JUnit records no failure" "! grep -q '<failure' '$VALID_JUNIT'"

echo "== an undeclared reference fails =="
BROKEN_REPO="$TEST_DIR/broken"
make_valid_root "$BROKEN_REPO/stacks/good"
make_undeclared_reference_root "$BROKEN_REPO/stacks/bad"
BROKEN_RC=0
BROKEN_OUT="$(run_validate "$BROKEN_REPO" 2>&1)" || BROKEN_RC=$?
BROKEN_JUNIT="$BROKEN_REPO/build/reports/junit-validate.xml"

assert_true "exits non-zero" "[ $BROKEN_RC -ne 0 ]"
assert_true "counts both root modules" '[[ "$BROKEN_OUT" == *"Validated 2 root module"* ]]'
assert_true "counts exactly one failure" '[[ "$BROKEN_OUT" == *"1 passed, 1 failed"* ]]'
assert_true "surfaces the diagnostic in the log" '[[ "$BROKEN_OUT" == *"declared"* ]]'
assert_true "JUnit records the failure" "grep -q '<failure' '$BROKEN_JUNIT'"
assert_true "JUnit blames the right directory" \
  "grep -A2 'stacks/bad' '$BROKEN_JUNIT' | grep -q '<failure'"
assert_true "the healthy root module is still reported" "grep -q 'stacks/good' '$BROKEN_JUNIT'"

echo "== the provider cache defaults inside the workspace, not \$HOME =="
# Terraform's plugin cache is not safe for concurrent use, and $HOME is shared by
# every agent on a CI host that runs jobs side by side. A $HOME-relative default
# makes two concurrent runs corrupt each other's provider binaries.
# Run with HOME redirected at a scratch directory, so the assertion below is a
# real observation rather than a restatement of the default: if the runner ever
# goes back to a $HOME-relative cache, the plugin-cache tree appears THERE and
# the test fails. Asserting on a path the test itself never creates would pass
# unconditionally, which is worse than having no assertion at all.
CACHE_REPO="$TEST_DIR/cache"
CACHE_HOME="$TEST_DIR/cache-home"
mkdir -p "$CACHE_HOME"
make_valid_root "$CACHE_REPO/stacks/app"
run_validate "$CACHE_REPO" env HOME="$CACHE_HOME" > /dev/null 2>&1 || true
assert_true "a workspace-local cache directory is created" \
  "[ -d '$CACHE_REPO/build/.terraform-plugin-cache' ]"
assert_true "no plugin cache is written under \$HOME" \
  "[ ! -d '$CACHE_HOME/.terraform.d/plugin-cache' ]"

# An explicit override still wins, so an operator with serialised jobs can point
# the cache at a durable shared location.
OVERRIDE_REPO="$TEST_DIR/cache-override"
make_valid_root "$OVERRIDE_REPO/stacks/app"
OVERRIDE_DIR="$TEST_DIR/explicit-cache"
run_validate "$OVERRIDE_REPO" env TF_PLUGIN_CACHE_DIR="$OVERRIDE_DIR" > /dev/null 2>&1 || true
assert_true "an exported TF_PLUGIN_CACHE_DIR is honoured" "[ -d '$OVERRIDE_DIR' ]"
assert_true "and the workspace-local default is then not created" \
  "[ ! -d '$OVERRIDE_REPO/build/.terraform-plugin-cache' ]"

echo "== no-op when the configured roots are absent =="
EMPTY_REPO="$TEST_DIR/empty"
mkdir -p "$EMPTY_REPO"
EMPTY_RC=0
EMPTY_OUT="$(run_validate "$EMPTY_REPO" 2>&1)" || EMPTY_RC=$?
EMPTY_JUNIT="$EMPTY_REPO/build/reports/junit-validate.xml"

assert_true "exits 0" "[ $EMPTY_RC -eq 0 ]"
assert_true "says it skipped" '[[ "$EMPTY_OUT" == *"skipping validate runner"* ]]'
assert_true "still emits a valid empty JUnit" \
  "[ -f '$EMPTY_JUNIT' ] && grep -q 'testsuites' '$EMPTY_JUNIT'"

echo "== a root directory holding no .tf files is a no-op too =="
NOTF_REPO="$TEST_DIR/notf"
mkdir -p "$NOTF_REPO/stacks"
NOTF_RC=0
NOTF_OUT="$(run_validate "$NOTF_REPO" 2>&1)" || NOTF_RC=$?
assert_true "exits 0" "[ $NOTF_RC -eq 0 ]"
assert_true "says no root modules were found" '[[ "$NOTF_OUT" == *"No root modules found"* ]]'

echo "== VALIDATE_ROOTS redirects the search =="
CUSTOM_REPO="$TEST_DIR/custom"
make_valid_root "$CUSTOM_REPO/infrastructure/app"
CUSTOM_RC=0
CUSTOM_OUT="$(run_validate "$CUSTOM_REPO" env VALIDATE_ROOTS=infrastructure 2>&1)" || CUSTOM_RC=$?
assert_true "exits 0" "[ $CUSTOM_RC -eq 0 ]"
assert_true "finds the root module under the custom root" \
  '[[ "$CUSTOM_OUT" == *"Validated 1 root module"* ]]'

CUSTOM_DEFAULT_RC=0
CUSTOM_DEFAULT_OUT="$(run_validate "$CUSTOM_REPO" 2>&1)" || CUSTOM_DEFAULT_RC=$?
assert_true "the default root does not reach it" \
  '[[ "$CUSTOM_DEFAULT_OUT" == *"skipping validate runner"* ]]'

echo "== vendored module sources are not validated =="
# `terraform init` vendors module sources under `.terraform`. Validating those
# would re-validate every dependency from a directory the consumer does not own.
VENDOR_REPO="$TEST_DIR/vendor"
make_valid_root "$VENDOR_REPO/stacks/app"
make_undeclared_reference_root "$VENDOR_REPO/stacks/app/.terraform/modules/dep"
VENDOR_RC=0
VENDOR_OUT="$(run_validate "$VENDOR_REPO" 2>&1)" || VENDOR_RC=$?
assert_true "exits 0 despite the broken vendored copy" "[ $VENDOR_RC -eq 0 ]"
assert_true "counts only the real root module" \
  '[[ "$VENDOR_OUT" == *"Validated 1 root module"* ]]'

echo "== the report survives XML metacharacters =="
# A diagnostic quoting an identifier renders `<`, `>` and `"` into the report.
# Unescaped, they produce XML the publisher rejects -- turning a legible test
# failure into an unparseable artifact.
XML_REPO="$TEST_DIR/xml"
mkdir -p "$XML_REPO/stacks/app"
cat > "$XML_REPO/stacks/app/main.tf" << 'EOF'
output "quoted" {
  value = "a & b < c > d \"quoted\" 'single'"
  value = "duplicate argument so validate emits a diagnostic"
}
EOF
XML_RC=0
run_validate "$XML_REPO" > /dev/null 2>&1 || XML_RC=$?
XML_JUNIT="$XML_REPO/build/reports/junit-validate.xml"
assert_true "exits non-zero" "[ $XML_RC -ne 0 ]"
assert_true "the JUnit report is well-formed XML" \
  "python3 -c \"import xml.etree.ElementTree as E; E.parse('$XML_JUNIT')\""

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
