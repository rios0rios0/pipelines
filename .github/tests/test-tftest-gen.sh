#!/usr/bin/env bash
set -e

# Test script for validating the tftest-gen smoke-test generator.
# Exercises gen_smoke_tests.py against synthetic terraform-module layouts
# and asserts the generated tests/smoke.tftest.hcl is well-formed.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$SCRIPTS_DIR/global/scripts/languages/terraform/tftest-gen/gen_smoke_tests.py"
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/terraform/tftest-gen/run.sh"
TEST_DIR="$(mktemp -d)"

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

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# =============================================================================
# Test 1: Minimal module -- one provider, one required var, no validations
# =============================================================================
echo "TEST 1: Minimal module (1 provider, 1 required var, no validations)"
# given
REPO1="$TEST_DIR/repo1"
mkdir -p "$REPO1"
cat > "$REPO1/main.tf" << 'HCL'
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}
HCL
cat > "$REPO1/variables.tf" << 'HCL'
variable "resource_group_name" {
  type = string
}
HCL

# when
python3 "$GEN" --repo-dir "$REPO1" >/dev/null

# then
SMOKE1="$REPO1/tests/smoke.tftest.hcl"
assert_true "smoke file was created" "[ -f '$SMOKE1' ]"
assert_true "auto-generated marker on line 1" \
  "head -n1 '$SMOKE1' | grep -q 'smoke.tftest.hcl -- auto-generated'"
assert_true "mock_provider for azurerm emitted" \
  "grep -q 'mock_provider \"azurerm\" {}' '$SMOKE1'"
assert_true "smoke_plans_successfully run emitted" \
  "grep -q 'run \"smoke_plans_successfully\"' '$SMOKE1'"
assert_true "resource_group_name stub emitted" \
  "grep -q 'resource_group_name = \"test-rg\"' '$SMOKE1'"
assert_true "no validation_rejects runs when no validations declared" \
  "! grep -q 'validation_rejects_invalid_' '$SMOKE1'"

# =============================================================================
# Test 2: Required variable with validation block -> validation_rejects test
# =============================================================================
echo "TEST 2: Required var with validation -> validation_rejects run"
# given
REPO2="$TEST_DIR/repo2"
mkdir -p "$REPO2"
cat > "$REPO2/main.tf" << 'HCL'
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}
HCL
cat > "$REPO2/variables.tf" << 'HCL'
variable "name" {
  type = string
  validation {
    condition     = length(var.name) > 0
    error_message = "name must not be empty"
  }
}
HCL

# when
python3 "$GEN" --repo-dir "$REPO2" >/dev/null

# then
SMOKE2="$REPO2/tests/smoke.tftest.hcl"
assert_true "validation_rejects_invalid_name run emitted" \
  "grep -q 'run \"validation_rejects_invalid_name\"' '$SMOKE2'"
assert_true "expect_failures targets var.name" \
  "grep -A2 'expect_failures' '$SMOKE2' | grep -q 'var.name'"
assert_true "invalid stub for string is empty string" \
  "grep -q 'name = \"\"' '$SMOKE2'"

# =============================================================================
# Test 3: object() validated variable is skipped
#   (regression guard: previously _invalid_stub returned {} for objects,
#    which failed terraform's type check BEFORE the validation block ran,
#    so the test would trigger a type error instead of exercising the guard)
# =============================================================================
echo "TEST 3: object() type with validation is skipped (type-error guard)"
# given
REPO3="$TEST_DIR/repo3"
mkdir -p "$REPO3"
cat > "$REPO3/main.tf" << 'HCL'
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}
HCL
cat > "$REPO3/variables.tf" << 'HCL'
variable "config" {
  type = object({
    name = string
    port = number
  })
  validation {
    condition     = var.config.port > 0
    error_message = "port must be positive"
  }
}
HCL

# when
python3 "$GEN" --repo-dir "$REPO3" >/dev/null

# then
SMOKE3="$REPO3/tests/smoke.tftest.hcl"
assert_true "smoke run still emitted for object-typed var" \
  "grep -q 'run \"smoke_plans_successfully\"' '$SMOKE3'"
assert_true "validation_rejects run is NOT emitted for object type" \
  "! grep -q 'validation_rejects_invalid_config' '$SMOKE3'"

# =============================================================================
# Test 4: Hand-written smoke file is preserved without --force, replaced with
# =============================================================================
echo "TEST 4: Hand-written smoke file respects --force flag"
# given
REPO4="$TEST_DIR/repo4"
mkdir -p "$REPO4/tests"
cat > "$REPO4/main.tf" << 'HCL'
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}
HCL
cat > "$REPO4/variables.tf" << 'HCL'
variable "name" { type = string }
HCL
cat > "$REPO4/tests/smoke.tftest.hcl" << 'HCL'
# Hand-written test -- do not overwrite.
run "custom" { command = plan }
HCL

# when (no --force)
python3 "$GEN" --repo-dir "$REPO4" >/dev/null

# then
SMOKE4="$REPO4/tests/smoke.tftest.hcl"
assert_true "hand-written content preserved without --force" \
  "grep -q 'Hand-written test' '$SMOKE4'"
assert_true "hand-written content does not contain auto-gen marker" \
  "! head -n1 '$SMOKE4' | grep -q 'auto-generated'"

# when (with --force)
python3 "$GEN" --repo-dir "$REPO4" --force >/dev/null

# then
assert_true "--force overwrites hand-written file with generated one" \
  "head -n1 '$SMOKE4' | grep -q 'auto-generated'"
assert_true "--force replaces custom run block" \
  "! grep -q 'run \"custom\"' '$SMOKE4'"

# =============================================================================
# Test 5: Optional (has default) variable produces no validation_rejects run
# =============================================================================
echo "TEST 5: Optional variable skipped from validation_rejects runs"
# given
REPO5="$TEST_DIR/repo5"
mkdir -p "$REPO5"
cat > "$REPO5/main.tf" << 'HCL'
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}
HCL
cat > "$REPO5/variables.tf" << 'HCL'
variable "region" {
  type    = string
  default = "eastus"
  validation {
    condition     = length(var.region) > 0
    error_message = "region must not be empty"
  }
}
HCL

# when
python3 "$GEN" --repo-dir "$REPO5" >/dev/null

# then
SMOKE5="$REPO5/tests/smoke.tftest.hcl"
assert_true "optional var produces no variables {} block" \
  "! grep -q 'region =' '$SMOKE5'"
assert_true "optional var produces no validation_rejects run" \
  "! grep -q 'validation_rejects_invalid_region' '$SMOKE5'"

# =============================================================================
# Test 6: run.sh shebang is POSIX sh (not bash) and executable
# =============================================================================
echo "TEST 6: run.sh is POSIX sh, not bash"
# given / when / then
assert_true "run.sh uses #!/usr/bin/env sh" \
  "head -n1 '$RUN_SH' | grep -qx '#!/usr/bin/env sh'"
assert_true "run.sh avoids bash-only BASH_SOURCE" \
  "! grep -q 'BASH_SOURCE' '$RUN_SH'"
assert_true "run.sh avoids bash-only pipefail" \
  "! grep -q 'pipefail' '$RUN_SH'"
assert_true "run.sh is executable" \
  "[ -x '$RUN_SH' ]"

# =============================================================================
# Test 7: makefiles/terraform.mk `test` recipe guard really short-circuits
#   (regression guard: GNU Make runs each tab-indented recipe line in its
#    own shell, so `exit 0` inside an `if ... fi` only terminates that
#    shell. Joining the guard and the init/test chain into a single
#    `if ... else ... fi` block is the fix -- this test proves the next
#    shell lines don't run when tests/ is absent)
# =============================================================================
echo "TEST 7: terraform.mk test recipe skips init/test when tests/ absent"
# given
REPO7="$TEST_DIR/repo7"
mkdir -p "$REPO7"
cp "$SCRIPTS_DIR/makefiles/terraform.mk" "$REPO7/Makefile"

# when -- run `make test` in a module with no tests/, with a shim that
# would fail loudly if terraform init / test ever runs
STUB_BIN="$TEST_DIR/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/terraform" << 'SHIM'
#!/usr/bin/env sh
echo "UNEXPECTED: terraform $* invoked inside guard" >&2
exit 99
SHIM
chmod +x "$STUB_BIN/terraform"

# then
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
MAKE_OUTPUT=$(cd "$REPO7" && PATH="$STUB_BIN:$PATH" make -s test 2>&1 || true)
assert_true "make test prints skip message when tests/ absent" \
  "echo \"\$MAKE_OUTPUT\" | grep -q 'skipping terraform test'"
# Stub would print 'UNEXPECTED: terraform ... invoked inside guard' if the
# guard failed to short-circuit. Its absence means init/test never ran.
assert_true "make test does NOT invoke terraform binary when tests/ absent" \
  "! echo \"\$MAKE_OUTPUT\" | grep -q 'UNEXPECTED: terraform'"

# given -- create a tests/*.tftest.hcl so the else branch runs
mkdir -p "$REPO7/tests"
echo "run \"noop\" { command = plan }" > "$REPO7/tests/smoke.tftest.hcl"

# when -- now the shim terraform should be invoked and fail loudly
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
MAKE_OUTPUT2=$(cd "$REPO7" && PATH="$STUB_BIN:$PATH" make -s test 2>&1 || true)

# then
assert_true "make test invokes terraform init when tests/ present" \
  "echo \"\$MAKE_OUTPUT2\" | grep -q 'UNEXPECTED: terraform init'"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
