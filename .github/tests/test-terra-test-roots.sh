#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016  # *_OUT/*_RC vars and the single-quoted condition
# strings are consumed inside assert_true's eval, which shellcheck cannot follow
set -e

# Test script for the terra-test tier's opt-in root-module run, `TERRA_TEST_ROOTS`.
# Exercises terra-test/run.sh and test-all/run.sh against synthetic repositories
# and asserts:
#   * unset, nothing changes: a root module's test is not run, and modules run
#     and report exactly as before
#   * set, a root's test runs despite a backend it cannot configure, its JUnit is
#     named after its path and reaches both aggregates, and a failure fails the run
#   * a repository with roots but no modules/ runs instead of skipping
#   * roots stay out of the module breadth figures
#   * test-all/run.sh detects a repository whose only tests are under the roots
#   * selection matches `terraform test`: `tests/e2e/` and vendored copies are not
#     roots, `.`/`./stacks` spell a root the same way, and no module runs twice
#   * a root's committed lock file is honoured, never upgraded or rewritten
#
# Every fixture is provider-less, so the cases run offline with no credentials;
# only the lock-file case uses the `null` provider, and it skips when that cannot
# be downloaded. Each run goes through `env -i` with HOME (and so the plugin
# cache) under the scratch directory, so neither a developer's exported
# TERRA_TEST_ROOTS nor their real provider cache can reach a case.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/terraform/terra-test/run.sh"
TEST_ALL_SH="$SCRIPTS_DIR/global/scripts/languages/terraform/test-all/run.sh"
TEST_DIR="$(mktemp -d)" || exit 1
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_HOME"

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
  echo -e "${YELLOW}SKIP: terraform not on PATH; the terra-test tier cannot be exercised.${NC}"
  exit 0
fi

# A provider-less configuration with one test: a variable, an output, and a
# `run` block asserting on the output. Nothing is downloaded.
#   $1 directory
#   $2 run-block name -- unique per fixture, so an aggregate can be searched for it
#   $3 `pass`, or `fail` to assert a value the output never has
#   $4 `backend` to declare a backend a plain `init` cannot configure (no address)
make_config() {
  local dir="$1" name="$2" outcome="$3" backend="${4:-}"
  local expected='hello world'
  if [ "$outcome" = 'fail' ]; then
    expected='a greeting this configuration never produces'
  fi
  mkdir -p "$dir/tests"
  {
    if [ "$backend" = 'backend' ]; then
      printf 'terraform {\n  backend "http" {}\n}\n\n'
    fi
    cat << 'EOF'
variable "name" {
  type    = string
  default = "world"
}

output "greeting" {
  value = "hello ${var.name}"
}
EOF
  } > "$dir/main.tf"
  cat > "$dir/tests/$name.tftest.hcl" << EOF
run "$name" {
  command = plan

  assert {
    condition     = output.greeting == "$expected"
    error_message = "unexpected greeting"
  }
}
EOF
}

# A FAILING test file planted where no root's test may come from -- a nested
# `tests/e2e/`, which `terraform test` never reads, or a vendored copy -- so the
# run stays green only if nothing treats it as a test of its own.
make_stray_test() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  cat > "$file" << 'EOF'
run "stray" {
  command = plan

  assert {
    condition     = false
    error_message = "a file outside tests/ was run"
  }
}
EOF
}

# Runs a tier script from a fixture repository, isolated from the caller's
# environment. Extra `NAME=value` assignments follow the two positional ones.
#   $1 repository  $2 script
run_tier() {
  local repo="$1" script="$2"
  shift 2
  (cd "$repo" && env -i PATH="$PATH" HOME="$TEST_HOME" ${TMPDIR:+"TMPDIR=$TMPDIR"} \
    SCRIPTS_DIR="$SCRIPTS_DIR" CHECKPOINT_DISABLE=1 REPORT_PATH=build/reports "$@" "$script")
}

echo "== unset: a root module's test is not run, modules behave as before =="
UNSET_REPO="$TEST_DIR/unset"
make_config "$UNSET_REPO/modules/tested" unset_module pass
# Fails if it is ever run, so the exit code alone would expose a leak.
make_config "$UNSET_REPO/stacks/app" unset_root fail
UNSET_RC=0
UNSET_OUT="$(run_tier "$UNSET_REPO" "$RUN_SH" 2>&1)" || UNSET_RC=$?
UNSET_TESTS="$UNSET_REPO/build/reports/terra-tests"

assert_true "exits 0" "[ $UNSET_RC -eq 0 ]"
assert_true "runs the module" '[[ "$UNSET_OUT" == *"Testing modules/tested..."* ]]'
assert_true "writes the module JUnit" "[ -f '$UNSET_TESTS/tested.xml' ]"
assert_true "does not run the root module" '[[ "$UNSET_OUT" != *"Testing stacks/app"* ]]'
assert_true "writes no root JUnit" "[ ! -f '$UNSET_TESTS/stacks_app.xml' ]"
assert_true "reports the module breadth as before" '[[ "$UNSET_OUT" == *"modules tested   : 1/1 (100%)"* ]]'
assert_true "reports the test cases as before" \
  '[[ "$UNSET_OUT" == *"test cases       : 1 (passed=1 failed=0 errored=0)"* ]]'
assert_true "adds no roots line to the summary" '[[ "$UNSET_OUT" != *"roots tested"* ]]'
assert_true "adds nothing about roots to the Markdown report" \
  "! grep -q 'Root modules' '$UNSET_REPO/build/reports/terra-coverage.md'"

NOMOD_REPO="$TEST_DIR/no-modules-unset"
make_config "$NOMOD_REPO/stacks/app" nomod_root pass
NOMOD_RC=0
NOMOD_OUT="$(run_tier "$NOMOD_REPO" "$RUN_SH" 2>&1)" || NOMOD_RC=$?
assert_true "no modules/ still skips with the original message" \
  '[ $NOMOD_RC -eq 0 ] && [[ "$NOMOD_OUT" == *"No modules/ directory; skipping terra-test."* ]]'

echo "== TERRA_TEST_ROOTS=stacks: the root module's test runs =="
SET_REPO="$TEST_DIR/set"
make_config "$SET_REPO/modules/tested" set_module pass
make_config "$SET_REPO/stacks/app" set_root pass backend
# The fixture only proves `-backend=false` if a plain `init` would fail on it.
SET_PROBE_RC=0
(cd "$SET_REPO/stacks/app" && env -i PATH="$PATH" HOME="$TEST_HOME" CHECKPOINT_DISABLE=1 \
  terraform init -input=false -no-color > /dev/null 2>&1) || SET_PROBE_RC=$?
rm -rf "$SET_REPO/stacks/app/.terraform" "$SET_REPO/stacks/app/.terraform.lock.hcl"
assert_true "precondition: a plain init cannot configure the root's backend" "[ $SET_PROBE_RC -ne 0 ]"

SET_RC=0
SET_OUT="$(run_tier "$SET_REPO" "$RUN_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || SET_RC=$?
SET_REPORTS="$SET_REPO/build/reports"
assert_true "exits 0" "[ $SET_RC -eq 0 ]"
assert_true "runs the root module" '[[ "$SET_OUT" == *"Testing stacks/app..."* ]]'
assert_true "still runs the module" '[[ "$SET_OUT" == *"Testing modules/tested..."* ]]'
assert_true "names the root's JUnit after its path" "[ -f '$SET_REPORTS/terra-tests/stacks_app.xml' ]"
assert_true "the root's JUnit records its case" "grep -q 'name=\"set_root\"' '$SET_REPORTS/terra-tests/stacks_app.xml'"
assert_true "the tier's aggregate carries the root's case" "grep -q 'name=\"set_root\"' '$SET_REPORTS/terra-tests.xml'"
assert_true "and the module's" "grep -q 'name=\"set_module\"' '$SET_REPORTS/terra-tests.xml'"
assert_true "the aggregate is well-formed XML" \
  "python3 -c \"import xml.etree.ElementTree as E; E.parse('$SET_REPORTS/terra-tests.xml')\""
assert_true "the summary reports the root" \
  '[[ "$SET_OUT" == *"roots tested     : 1 (TERRA_TEST_ROOTS='"'"'stacks'"'"')"* ]]'
assert_true "the Markdown report lists the root" "grep -q '^- \`stacks/app\`' '$SET_REPORTS/terra-coverage.md'"

echo "== a failing root test fails the run =="
FAIL_REPO="$TEST_DIR/fail"
make_config "$FAIL_REPO/modules/tested" fail_module pass
make_config "$FAIL_REPO/stacks/bad" fail_bad_root fail
make_config "$FAIL_REPO/stacks/good" fail_good_root pass
FAIL_RC=0
FAIL_OUT="$(run_tier "$FAIL_REPO" "$RUN_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || FAIL_RC=$?
FAIL_TESTS="$FAIL_REPO/build/reports/terra-tests"
assert_true "exits non-zero" "[ $FAIL_RC -ne 0 ]"
assert_true "the failing root's JUnit records the failure" "grep -q '<failure' '$FAIL_TESTS/stacks_bad.xml'"
assert_true "keeps going: the next root still runs" "grep -q 'name=\"fail_good_root\"' '$FAIL_TESTS/stacks_good.xml'"
assert_true "the summary counts the failure" '[[ "$FAIL_OUT" == *"failed=1"* ]]'

echo "== no modules/ directory: roots run instead of the skip =="
ONLY_REPO="$TEST_DIR/roots-only"
make_config "$ONLY_REPO/stacks/app" only_root pass
ONLY_RC=0
ONLY_OUT="$(run_tier "$ONLY_REPO" "$RUN_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || ONLY_RC=$?
assert_true "exits 0" "[ $ONLY_RC -eq 0 ]"
assert_true "does not print the skip" '[[ "$ONLY_OUT" != *"skipping terra-test"* ]]'
assert_true "runs the root module" '[[ "$ONLY_OUT" == *"Testing stacks/app..."* ]]'
assert_true "writes its JUnit" "[ -f '$ONLY_REPO/build/reports/terra-tests/stacks_app.xml' ]"

EMPTY_REPO="$TEST_DIR/roots-empty"
mkdir -p "$EMPTY_REPO/stacks/app"
EMPTY_RC=0
EMPTY_OUT="$(run_tier "$EMPTY_REPO" "$RUN_SH" TERRA_TEST_ROOTS='stacks stakcs' 2>&1)" || EMPTY_RC=$?
assert_true "with nothing to test it still skips, naming the roots" \
  '[ $EMPTY_RC -eq 0 ] && [[ "$EMPTY_OUT" == *"no root module tests under TERRA_TEST_ROOTS"* ]]'
assert_true "a root that does not exist is reported, not skipped in silence" \
  '[[ "$EMPTY_OUT" == *"TERRA_TEST_ROOTS names '"'"'stakcs'"'"', which is not a directory"* ]]'

echo "== roots stay out of the module breadth figures =="
BREADTH_REPO="$TEST_DIR/breadth"
make_config "$BREADTH_REPO/modules/tested" breadth_module pass
mkdir -p "$BREADTH_REPO/modules/untested"
printf 'output "x" {\n  value = 1\n}\n' > "$BREADTH_REPO/modules/untested/main.tf"
make_config "$BREADTH_REPO/stacks/app" breadth_root pass
BREADTH_RC=0
BREADTH_OUT="$(run_tier "$BREADTH_REPO" "$RUN_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || BREADTH_RC=$?
BREADTH_REPORTS="$BREADTH_REPO/build/reports"
assert_true "exits 0" "[ $BREADTH_RC -eq 0 ]"
assert_true "modules tested stays modules over modules" '[[ "$BREADTH_OUT" == *"modules tested   : 1/2 (50%)"* ]]'
assert_true "the root's case still counts as a test case" '[[ "$BREADTH_OUT" == *"test cases       : 2 (passed=2"* ]]'
assert_true "the JSON report counts modules only" \
  "grep -q '\"modules\": { \"tested\": 1, \"total\": 2, \"percent\": 50 }' '$BREADTH_REPORTS/terra-coverage.json'"
assert_true "the Cobertura report counts modules only" \
  "grep -q 'lines-covered=\"1\" lines-valid=\"2\"' '$BREADTH_REPORTS/terra-coverage.xml'"
assert_true "and has no class for the root" "! grep -q 'stacks' '$BREADTH_REPORTS/terra-coverage.xml'"
assert_true "the Markdown figure is unchanged" "grep -q '\*\*1 / 2 (50%)\*\*' '$BREADTH_REPORTS/terra-coverage.md'"

echo "== test-all detects a repository whose only tests are under the roots =="
ALL_REPO="$TEST_DIR/all"
make_config "$ALL_REPO/stacks/app" all_root pass
ALL_RC=0
ALL_OUT="$(run_tier "$ALL_REPO" "$TEST_ALL_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || ALL_RC=$?
ALL_MERGED="$ALL_REPO/build/reports/junit-terra-all.xml"
assert_true "exits 0" "[ $ALL_RC -eq 0 ]"
assert_true "runs tier 1" '[[ "$ALL_OUT" == *"=== Tier 1: terraform test (terra-test) ==="* ]]'
assert_true "reports tier 1 as run" '[[ "$ALL_OUT" == *"tier 1 (terra-test)   : exit=0 (ran=1)"* ]]'
assert_true "the merged JUnit carries the root's case" "grep -q 'name=\"all_root\"' '$ALL_MERGED'"
assert_true "the merged JUnit is well-formed XML" \
  "python3 -c \"import xml.etree.ElementTree as E; E.parse('$ALL_MERGED')\""

ALL_UNSET_RC=0
rm -rf "$ALL_REPO/build"
ALL_UNSET_OUT="$(run_tier "$ALL_REPO" "$TEST_ALL_SH" 2>&1)" || ALL_UNSET_RC=$?
assert_true "unset, the same repository still has no tests" \
  '[ $ALL_UNSET_RC -eq 0 ] && [[ "$ALL_UNSET_OUT" == *"No Terraform tests detected"* ]]'
assert_true "and still emits the empty JUnit" "grep -q '<testsuites name=\"terra-all\"/>' '$ALL_MERGED'"

ALL_FAIL_REPO="$TEST_DIR/all-fail"
make_config "$ALL_FAIL_REPO/stacks/app" all_fail_root fail
ALL_FAIL_RC=0
ALL_FAIL_OUT="$(run_tier "$ALL_FAIL_REPO" "$TEST_ALL_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || ALL_FAIL_RC=$?
assert_true "a failing root fails test-all" "[ $ALL_FAIL_RC -ne 0 ]"
assert_true "and is blamed on tier 1" '[[ "$ALL_FAIL_OUT" == *"tier 1 (terra-test)   : exit=1 (ran=1)"* ]]'

echo "== selection matches terraform test: tests/e2e/ and vendored copies are not roots =="
SELECT_REPO="$TEST_DIR/select"
make_config "$SELECT_REPO/stacks/app" select_root pass
make_stray_test "$SELECT_REPO/stacks/app/tests/e2e/apply.tftest.hcl"
make_stray_test "$SELECT_REPO/stacks/e2e-only/tests/e2e/apply.tftest.hcl"
make_stray_test "$SELECT_REPO/stacks/vendored/.terraform/modules/dep/tests/dep.tftest.hcl"
make_stray_test "$SELECT_REPO/stacks/.terragrunt-cache/abc/def/stacks/app/tests/app.tftest.hcl"
SELECT_RC=0
SELECT_OUT="$(run_tier "$SELECT_REPO" "$RUN_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || SELECT_RC=$?
assert_true "exits 0" "[ $SELECT_RC -eq 0 ]"
assert_true "tests exactly one root" '[[ "$SELECT_OUT" == *"roots tested     : 1 "* ]]'
assert_true "never treats a test file as a root" '[[ "$SELECT_OUT" != *"Testing stacks/app/tests"* ]]'
assert_true "a root with only tests/e2e/ is not a root" '[[ "$SELECT_OUT" != *"Testing stacks/e2e-only"* ]]'
assert_true "vendored copies are not roots" \
  '[[ "$SELECT_OUT" != *"Testing stacks/vendored"* && "$SELECT_OUT" != *".terragrunt-cache"* ]]'

SELECT_ALL_REPO="$TEST_DIR/select-all"
make_stray_test "$SELECT_ALL_REPO/stacks/e2e-only/tests/e2e/apply.tftest.hcl"
SELECT_ALL_RC=0
SELECT_ALL_OUT="$(run_tier "$SELECT_ALL_REPO" "$TEST_ALL_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || SELECT_ALL_RC=$?
assert_true "test-all agrees: tests/e2e/ alone is nothing to run" \
  '[ $SELECT_ALL_RC -eq 0 ] && [[ "$SELECT_ALL_OUT" == *"No Terraform tests detected"* ]]'

echo "== spelling: ./stacks and . name a root the same way, and no module runs twice =="
DOT_REPO="$TEST_DIR/dot"
make_config "$DOT_REPO/stacks/app" dot_root pass
DOT_RC=0
DOT_OUT="$(run_tier "$DOT_REPO" "$RUN_SH" TERRA_TEST_ROOTS=./stacks 2>&1)" || DOT_RC=$?
assert_true "./stacks exits 0" "[ $DOT_RC -eq 0 ]"
assert_true "./stacks names the JUnit as stacks does" \
  "[ -f '$DOT_REPO/build/reports/terra-tests/stacks_app.xml' ]"
assert_true "./stacks still reaches the aggregate" \
  "grep -q 'name=\"dot_root\"' '$DOT_REPO/build/reports/terra-tests.xml'"

WIDE_REPO="$TEST_DIR/wide"
make_config "$WIDE_REPO/modules/tested" wide_module pass
make_config "$WIDE_REPO/stacks/app" wide_root pass
# The repository root is itself a root module here, so `.` resolves to it too.
make_config "$WIDE_REPO" wide_repo_root pass
WIDE_RC=0
WIDE_OUT="$(run_tier "$WIDE_REPO" "$RUN_SH" TERRA_TEST_ROOTS=. 2>&1)" || WIDE_RC=$?
WIDE_REPORTS="$WIDE_REPO/build/reports"
assert_true ". exits 0" "[ $WIDE_RC -eq 0 ]"
assert_true "runs the module once" \
  "[ \"\$(grep -c 'Testing modules/tested' <<< \"\$WIDE_OUT\")\" -eq 1 ] && [ ! -f '$WIDE_REPORTS/terra-tests/modules_tested.xml' ]"
assert_true "tests the two roots" '[[ "$WIDE_OUT" == *"roots tested     : 2 "* ]]'
assert_true "no JUnit file is hidden from the *.xml glob" \
  "[ -z \"\$(find '$WIDE_REPORTS/terra-tests' -name '.*' -type f)\" ]"
assert_true "the repository root's case reaches the aggregate" \
  "grep -q 'name=\"wide_repo_root\"' '$WIDE_REPORTS/terra-tests.xml'"
assert_true "as does the stack's" "grep -q 'name=\"wide_root\"' '$WIDE_REPORTS/terra-tests.xml'"

echo "== a root's committed lock file is honoured, not upgraded =="
# `-upgrade` would resolve the newest null provider the constraint allows and
# rewrite the lock file in the working tree; the root must keep what it locks.
LOCK_REPO="$TEST_DIR/lock"
LOCK_ROOT="$LOCK_REPO/stacks/app"
make_config "$LOCK_ROOT" lock_root pass
cat > "$LOCK_ROOT/providers.tf" << 'EOF'
terraform {
  required_providers {
    null = {
      version = "3.1.1"
    }
  }
}

resource "null_resource" "pinned" {}
EOF
# Seeded into the runner's default plugin cache (under the isolated HOME), which
# the provider mirror then serves from -- so the run itself needs no network.
LOCK_CACHE="$TEST_HOME/.terraform.d/plugin-cache"
mkdir -p "$LOCK_CACHE"
LOCK_SEED_RC=0
(cd "$LOCK_ROOT" && env -i PATH="$PATH" HOME="$TEST_HOME" ${TMPDIR:+"TMPDIR=$TMPDIR"} CHECKPOINT_DISABLE=1 \
  TF_PLUGIN_CACHE_DIR="$LOCK_CACHE" terraform init -backend=false -input=false -no-color > /dev/null 2>&1) \
  || LOCK_SEED_RC=$?
if [ "$LOCK_SEED_RC" -ne 0 ] || [ ! -f "$LOCK_ROOT/.terraform.lock.hcl" ]; then
  echo -e "${YELLOW}  SKIP: could not download the null provider 3.1.1 to seed the lock file (offline?).${NC}"
else
  # Widen the constraint the way a real root does, so only the lock file holds 3.1.1.
  sed -i.bak 's/version = "3.1.1"/version = ">= 3.0.0"/' "$LOCK_ROOT/providers.tf"
  rm -rf "$LOCK_ROOT/.terraform" "$LOCK_ROOT/providers.tf.bak"
  cp "$LOCK_ROOT/.terraform.lock.hcl" "$TEST_DIR/lock.before"
  LOCK_RC=0
  LOCK_OUT="$(run_tier "$LOCK_REPO" "$RUN_SH" TERRA_TEST_ROOTS=stacks 2>&1)" || LOCK_RC=$?
  assert_true "exits 0" "[ $LOCK_RC -eq 0 ]"
  assert_true "leaves the committed lock file byte-for-byte as it was" \
    "cmp -s '$TEST_DIR/lock.before' '$LOCK_ROOT/.terraform.lock.hcl'"
  assert_true "installs the version the lock file pins" \
    "[ \"\$(ls \"$LOCK_ROOT\"/.terraform/providers/registry.terraform.io/*/null)\" = '3.1.1' ]"
fi

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
