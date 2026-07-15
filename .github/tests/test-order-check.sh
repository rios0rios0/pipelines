#!/usr/bin/env bash
# shellcheck disable=SC2034  # captured *_OUT/*_RC vars are consumed inside assert_true's eval'd condition
set -e

# Test script for the Terragrunt file-ordering checker/fixer.
# Exercises check_order.py against synthetic Terragrunt layouts and asserts
# both the detection (check mode) and the safe reordering (--fix mode) of:
#   * root.hcl dependency blocks + inputs grouping
#   * stacks/*/variables.tf .HCL/.ENV sections
#   * **/providers.tf provider weight ordering (stacks + modules)
#   * stacks/*/outputs.tf main.tf declaration ordering

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OC="$SCRIPTS_DIR/global/scripts/languages/terraform/order-check/check_order.py"
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/terraform/order-check/run.sh"
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

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

oc() { REPORT_PATH="$(mktemp -d)/reports" python3 "$OC" "$@"; }

# Build a correct, in-standard repo at $1.
make_clean_repo() {
  local repo="$1"
  mkdir -p "$repo/environments/04_app" "$repo/stacks/04_app" "$repo/modules/foo"

  cat > "$repo/environments/04_app/root.hcl" << 'HCL'
dependency "shared_common" {
  config_path = "${get_path_to_repo_root()}//environments/01_shared/02_common"
}

dependency "kubernetes" {
  config_path = "${get_path_to_repo_root()}//environments/03_kubernetes/x"
}

terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  tags = local.tags

  registry = dependency.shared_common.outputs.registry

  kube = dependency.kubernetes.outputs.kube

  image = "app:1.0.0"
}
HCL

  cat > "$repo/stacks/04_app/variables.tf" << 'HCL'
// SET ON .HCL

variable "tags" {
  type = map(string)
}

variable "registry" {
  type = string
}

variable "kube" {
  type = string
}

variable "image" {
  type = string
}

// SET ON .ENV

variable "environment" {
  type = string
}
HCL

  cat > "$repo/stacks/04_app/providers.tf" << 'HCL'
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    helm = {
      source = "hashicorp/helm"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "helm" {}

provider "random" {}
HCL

  cat > "$repo/stacks/04_app/main.tf" << 'HCL'
module "alpha" {
  source = "../../modules/foo"
}

module "beta" {
  source = "../../modules/foo"
}
HCL

  cat > "$repo/stacks/04_app/outputs.tf" << 'HCL'
output "a" {
  value = module.alpha.id
}

output "b" {
  value = module.beta.id
}
HCL

  cat > "$repo/modules/foo/providers.tf" << 'HCL'
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}
HCL
}

# =============================================================================
# Test 1: A correct repo passes cleanly and writes a JUnit report.
# =============================================================================
echo "TEST 1: in-standard repo passes with no errors"
# given
R1="$TEST_DIR/clean"
make_clean_repo "$R1"
# when
OUT1="$(REPORT_PATH="$R1/build/reports" python3 "$OC" --repo-dir "$R1" 2>&1)"; RC1=$?
# then
assert_true "exit code 0 on clean repo" "[ $RC1 -eq 0 ]"
assert_true "prints 'no ordering errors'" "echo \"\$OUT1\" | grep -q 'no ordering errors'"
assert_true "JUnit report written" "[ -f '$R1/build/reports/junit-order-check.xml' ]"
assert_true "JUnit reports zero failures" \
  "grep -q 'testsuites name=\"order-check\" tests=\"[0-9]*\" failures=\"0\"' '$R1/build/reports/junit-order-check.xml'"

# =============================================================================
# Test 2: root.hcl dependency blocks out of order -> detected, then fixed.
# =============================================================================
echo "TEST 2: root.hcl dependency blocks out of order"
# given
R2="$TEST_DIR/deps"
make_clean_repo "$R2"
cat > "$R2/environments/04_app/root.hcl" << 'HCL'
dependency "kubernetes" {
  config_path = "${get_path_to_repo_root()}//environments/03_kubernetes/x"
}

dependency "shared_common" {
  config_path = "${get_path_to_repo_root()}//environments/01_shared/02_common"
}

terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  registry = dependency.shared_common.outputs.registry
  kube     = dependency.kubernetes.outputs.kube
}
HCL
# when (check)
set +e; OUT2="$(oc --repo-dir "$R2" 2>&1)"; RC2=$?; set -e
# then
assert_true "check fails (exit 1)" "[ $RC2 -eq 1 ]"
assert_true "flags root-hcl-deps" "echo \"\$OUT2\" | grep -q 'root-hcl-deps'"
# when (fix)
oc --repo-dir "$R2" --fix >/dev/null 2>&1
set +e; oc --repo-dir "$R2" >/dev/null 2>&1; RC2B=$?; set -e
# then
assert_true "re-check passes after --fix" "[ $RC2B -eq 0 ]"
assert_true "shared_common now precedes kubernetes" \
  "awk '/dependency \"shared_common\"/{s=NR} /dependency \"kubernetes\"/{k=NR} END{exit !(s<k)}' '$R2/environments/04_app/root.hcl'"

# =============================================================================
# Test 3: root.hcl inputs not grouped by dependency number -> detected + fixed.
# =============================================================================
echo "TEST 3: root.hcl inputs out of dependency-number order"
# given
R3="$TEST_DIR/inputs"
make_clean_repo "$R3"
cat > "$R3/environments/04_app/root.hcl" << 'HCL'
dependency "shared_common" {
  config_path = "${get_path_to_repo_root()}//environments/01_shared/02_common"
}

dependency "kubernetes" {
  config_path = "${get_path_to_repo_root()}//environments/03_kubernetes/x"
}

terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  tags = local.tags

  kube = dependency.kubernetes.outputs.kube

  registry = dependency.shared_common.outputs.registry

  image = "app:1.0.0"
}
HCL
# when (check)
set +e; OUT3="$(oc --repo-dir "$R3" 2>&1)"; RC3=$?; set -e
# then
assert_true "flags root-hcl-inputs" "echo \"\$OUT3\" | grep -q 'root-hcl-inputs'"
# when (fix)
oc --repo-dir "$R3" --fix >/dev/null 2>&1
# then
assert_true "registry(01) now precedes kube(03) in inputs" \
  "awk '/registry = dependency/{r=NR} /kube = dependency/{k=NR} END{exit !(r<k)}' '$R3/environments/04_app/root.hcl'"
assert_true "tags (local) stays first in inputs" \
  "awk '/tags = local/{t=NR} /registry = dependency/{r=NR} END{exit !(t<r)}' '$R3/environments/04_app/root.hcl'"
assert_true "image literal stays last in inputs" \
  "awk '/kube = dependency/{k=NR} /image  *= /{i=NR} END{exit !(k<i)}' '$R3/environments/04_app/root.hcl'"

# =============================================================================
# Test 4: variables.tf .HCL out of dependency order; tags/literals unconstrained.
# =============================================================================
echo "TEST 4: variables.tf .HCL ordering (deps only; tags/literals free)"
# given
R4="$TEST_DIR/vars"
make_clean_repo "$R4"
cat > "$R4/stacks/04_app/variables.tf" << 'HCL'
// SET ON .HCL

variable "tags" {
  type = map(string)
}

variable "kube" {
  type = string
}

variable "registry" {
  type = string
}

variable "image" {
  type = string
}

// SET ON .ENV

variable "environment" {
  type = string
}
HCL
# when (check)
set +e; OUT4="$(oc --repo-dir "$R4" 2>&1)"; RC4=$?; set -e
# then
assert_true "flags variables-order" "echo \"\$OUT4\" | grep -q 'variables-order'"
assert_true "does NOT blame 'tags' (local, unconstrained)" \
  "! echo \"\$OUT4\" | grep -q \"'tags'\""
# when (fix)
oc --repo-dir "$R4" --fix >/dev/null 2>&1
set +e; oc --repo-dir "$R4" >/dev/null 2>&1; RC4B=$?; set -e
# then
assert_true "re-check passes after --fix" "[ $RC4B -eq 0 ]"
assert_true "registry(01) now precedes kube(03)" \
  "awk '/variable \"registry\"/{r=NR} /variable \"kube\"/{k=NR} END{exit !(r<k)}' '$R4/stacks/04_app/variables.tf'"
assert_true ".ENV section still after .HCL section" \
  "awk '/SET ON .HCL/{h=NR} /SET ON .ENV/{e=NR} END{exit !(h<e)}' '$R4/stacks/04_app/variables.tf'"
assert_true "environment var stays in .ENV section" \
  "awk '/SET ON .ENV/{e=NR} /variable \"environment\"/{v=NR} END{exit !(e<v)}' '$R4/stacks/04_app/variables.tf'"

# =============================================================================
# Test 5: .ENV section before .HCL -> error.
# =============================================================================
echo "TEST 5: variables.tf with .ENV before .HCL"
# given
R5="$TEST_DIR/sections"
make_clean_repo "$R5"
# variables.tf declares every clean-repo input (tags/registry/kube/image) so the
# only fault here is the section order -- rule F (dead inputs) stays silent.
cat > "$R5/stacks/04_app/variables.tf" << 'HCL'
// SET ON .ENV

variable "environment" {
  type = string
}

// SET ON .HCL

variable "tags" {
  type = map(string)
}

variable "registry" {
  type = string
}

variable "kube" {
  type = string
}

variable "image" {
  type = string
}
HCL
# when
set +e; OUT5="$(oc --repo-dir "$R5" 2>&1)"; RC5=$?; set -e
# then
assert_true "flags variables-sections" "echo \"\$OUT5\" | grep -q 'variables-sections'"
assert_true "exit 1" "[ $RC5 -eq 1 ]"

# =============================================================================
# Test 6: missing section markers -> warning only (not a hard failure).
# =============================================================================
echo "TEST 6: variables.tf without section markers -> warning"
# given
R6="$TEST_DIR/nomarkers"
make_clean_repo "$R6"
# declares every clean-repo input so rule F stays silent; the only fault is the
# missing section markers.
cat > "$R6/stacks/04_app/variables.tf" << 'HCL'
variable "tags" {
  type = map(string)
}

variable "registry" {
  type = string
}

variable "kube" {
  type = string
}

variable "image" {
  type = string
}
HCL
# when
set +e; OUT6="$(oc --repo-dir "$R6" 2>&1)"; RC6=$?; set -e
# then
assert_true "emits variables-markers warning" "echo \"\$OUT6\" | grep -q 'variables-markers'"
assert_true "missing markers is WARNING not ERROR" "echo \"\$OUT6\" | grep -q 'WARNING'"
assert_true "exit 0 (warning does not fail CI)" "[ $RC6 -eq 0 ]"

# =============================================================================
# Test 7: providers.tf out of weight order (stack + module) -> detected + fixed.
# =============================================================================
echo "TEST 7: providers.tf heaviest->lightest ordering (stacks + modules)"
# given
R7="$TEST_DIR/providers"
make_clean_repo "$R7"
cat > "$R7/stacks/04_app/providers.tf" << 'HCL'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
    azurerm = {
      source = "hashicorp/azurerm"
    }
    helm = {
      source = "hashicorp/helm"
    }
  }
}

provider "random" {}

provider "azurerm" {
  features {}
}

provider "helm" {}
HCL
# module providers.tf out of order too
cat > "$R7/modules/foo/providers.tf" << 'HCL'
terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}
HCL
# when (check)
set +e; OUT7="$(oc --repo-dir "$R7" 2>&1)"; RC7=$?; set -e
# then
assert_true "flags providers in stack" "echo \"\$OUT7\" | grep -q 'stacks/04_app/providers.tf'"
assert_true "flags providers in module too" "echo \"\$OUT7\" | grep -q 'modules/foo/providers.tf'"
# when (fix)
oc --repo-dir "$R7" --fix >/dev/null 2>&1
set +e; oc --repo-dir "$R7" >/dev/null 2>&1; RC7B=$?; set -e
# then
assert_true "re-check passes after --fix" "[ $RC7B -eq 0 ]"
assert_true "azurerm now precedes random in required_providers" \
  "awk '/azurerm = {/{a=NR} /random = {/{r=NR} END{exit !(a<r)}' '$R7/stacks/04_app/providers.tf'"
assert_true "azurerm provider block precedes random provider block" \
  "awk '/provider \"azurerm\"/{a=NR} /provider \"random\"/{r=NR} END{exit !(a<r)}' '$R7/stacks/04_app/providers.tf'"

# =============================================================================
# Test 8: unknown provider -> warning; --fix pins it and sorts the rest safely.
# =============================================================================
echo "TEST 8: unknown provider warns and is pinned by --fix"
# given
R8="$TEST_DIR/unknown"
make_clean_repo "$R8"
cat > "$R8/stacks/04_app/providers.tf" << 'HCL'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
    mysteryprovider = {
      source = "acme/mysteryprovider"
    }
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}
HCL
BEFORE_COUNT=$(grep -c ' = {' "$R8/stacks/04_app/providers.tf")
# when
set +e; OUT8="$(oc --repo-dir "$R8" 2>&1)"; set -e
oc --repo-dir "$R8" --fix >/dev/null 2>&1
AFTER_COUNT=$(grep -c ' = {' "$R8/stacks/04_app/providers.tf")
# then
assert_true "warns about unknown provider" \
  "echo \"\$OUT8\" | grep -q 'not in the ranking'"
assert_true "names mysteryprovider in the warning" \
  "echo \"\$OUT8\" | grep -q 'mysteryprovider'"
assert_true "no provider entry lost during --fix (content preserved)" \
  "[ '$BEFORE_COUNT' = '$AFTER_COUNT' ]"
assert_true "azurerm sorted before random among known providers" \
  "awk '/azurerm = {/{a=NR} /random = {/{r=NR} END{exit !(a<r)}' '$R8/stacks/04_app/providers.tf'"

# =============================================================================
# Test 9: outputs.tf out of main*.tf declaration order -> detected + fixed.
# =============================================================================
echo "TEST 9: outputs.tf follows main.tf module declaration order"
# given
R9="$TEST_DIR/outputs"
make_clean_repo "$R9"
cat > "$R9/stacks/04_app/outputs.tf" << 'HCL'
output "b" {
  value = module.beta.id
}

output "passthrough" {
  value = var.registry
}

output "a" {
  value = module.alpha.id
}
HCL
# when (check)
set +e; OUT9="$(oc --repo-dir "$R9" 2>&1)"; set -e
# then
assert_true "flags outputs ordering" "echo \"\$OUT9\" | grep -q 'outputs'"
# when (fix)
oc --repo-dir "$R9" --fix >/dev/null 2>&1
set +e; oc --repo-dir "$R9" >/dev/null 2>&1; RC9B=$?; set -e
# then
assert_true "re-check passes after --fix" "[ $RC9B -eq 0 ]"
assert_true "output a (module.alpha) precedes output b (module.beta)" \
  "awk '/output \"a\"/{a=NR} /output \"b\"/{b=NR} END{exit !(a<b)}' '$R9/stacks/04_app/outputs.tf'"
assert_true "passthrough output preserved (not dropped)" \
  "grep -q 'output \"passthrough\"' '$R9/stacks/04_app/outputs.tf'"

# =============================================================================
# Test 10: --fix is idempotent and preserves all blocks.
# =============================================================================
echo "TEST 10: --fix idempotency and block preservation"
# given
R10="$TEST_DIR/idem"
make_clean_repo "$R10"
# scramble a few files
cat > "$R10/stacks/04_app/providers.tf" << 'HCL'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
    azurerm = {
      source = "hashicorp/azurerm"
    }
    helm = {
      source = "hashicorp/helm"
    }
  }
}
HCL
PROV_BEFORE=$(grep -c ' = {' "$R10/stacks/04_app/providers.tf")
# when (first fix)
oc --repo-dir "$R10" --fix >/dev/null 2>&1
FIRST="$(cat "$R10/stacks/04_app/providers.tf")"
# when (second fix)
OUT10="$(oc --repo-dir "$R10" --fix 2>&1)"
SECOND="$(cat "$R10/stacks/04_app/providers.tf")"
PROV_AFTER=$(grep -c ' = {' "$R10/stacks/04_app/providers.tf")
# then
assert_true "second --fix rewrites 0 files (idempotent)" \
  "echo \"\$OUT10\" | grep -q 'rewrote 0 file'"
assert_true "file content identical across two fixes" "[ \"\$FIRST\" = \"\$SECOND\" ]"
assert_true "provider entry count preserved" "[ '$PROV_BEFORE' = '$PROV_AFTER' ]"

# =============================================================================
# Test 11: .terraform-order.json overrides ranking and ignores paths.
# =============================================================================
echo "TEST 11: .terraform-order.json override + ignore"
# given -- declare a ranking where 'random' outranks 'azurerm'
R11="$TEST_DIR/config"
make_clean_repo "$R11"
cat > "$R11/stacks/04_app/providers.tf" << 'HCL'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}
HCL
cat > "$R11/.terraform-order.json" << 'JSON'
{
  "provider_order": ["random", "azurerm"],
  "ignore": ["modules/**"]
}
JSON
# when -- random-before-azurerm is now in-order, so providers check passes;
#         the (out-of-order by default) module file is ignored.
set +e; OUT11="$(oc --repo-dir "$R11" 2>&1)"; set -e
# then
assert_true "custom ranking makes random-before-azurerm valid" \
  "! echo \"\$OUT11\" | grep -q 'stacks/04_app/providers.tf'"
assert_true "ignore glob skips modules/**" \
  "! echo \"\$OUT11\" | grep -q 'modules/foo/providers.tf'"

# =============================================================================
# Test 12: run.sh is POSIX sh and executable.
# =============================================================================
echo "TEST 12: run.sh is POSIX sh, not bash"
assert_true "run.sh uses #!/usr/bin/env sh" \
  "head -n1 '$RUN_SH' | grep -qx '#!/usr/bin/env sh'"
assert_true "run.sh avoids bash-only BASH_SOURCE" "! grep -q 'BASH_SOURCE' '$RUN_SH'"
assert_true "run.sh avoids bash-only pipefail" "! grep -q 'pipefail' '$RUN_SH'"
assert_true "run.sh is executable" "[ -x '$RUN_SH' ]"
assert_true "check_order.py is executable" "[ -x '$OC' ]"

# =============================================================================
# Test 13: a non-Terragrunt repo (no environments/stacks) passes cleanly.
# =============================================================================
echo "TEST 13: empty/non-terragrunt repo exits 0"
# given
R13="$TEST_DIR/empty"
mkdir -p "$R13"
# when
set +e; oc --repo-dir "$R13" >/dev/null 2>&1; RC13=$?; set -e
# then
assert_true "exit 0 on repo with nothing to check" "[ $RC13 -eq 0 ]"

# =============================================================================
# Test 14: --fix never corrupts heredocs or block comments containing braces.
#   (regression guard: a bare `}` inside a heredoc body or a `/* { } */` block
#    comment must not be counted as a structural brace, or find_matching_brace
#    would end a block early and the reorder would scramble the file)
# =============================================================================
echo "TEST 14: --fix preserves heredoc + block-comment braces while reordering"
# given
R14="$TEST_DIR/heredoc"
make_clean_repo "$R14"
# tags/image (unconstrained clean-repo inputs) are declared too so rule F stays
# silent; they are pinned by the fixer, leaving the registry/kube reorder intact.
cat > "$R14/stacks/04_app/variables.tf" << 'HCL'
// SET ON .HCL

variable "kube" {
  /* config note: this resource uses { and } tokens */
  type = string
}

variable "registry" {
  type    = string
  default = <<-EOT
    a dangling close brace } sits in this prose
  EOT
}

variable "tags" {
  type = map(string)
}

variable "image" {
  type = string
}

// SET ON .ENV

variable "environment" {
  type = string
}
HCL
# when (fix)
oc --repo-dir "$R14" --fix >/dev/null 2>&1
set +e; oc --repo-dir "$R14" >/dev/null 2>&1; RC14=$?; set -e
# then
assert_true "re-check passes after --fix (no corruption)" "[ $RC14 -eq 0 ]"
assert_true "registry(01) reordered before kube(03)" \
  "awk '/variable \"registry\"/{r=NR} /variable \"kube\"/{k=NR} END{exit !(r<k)}' '$R14/stacks/04_app/variables.tf'"
assert_true "heredoc body line preserved intact" \
  "grep -qF 'a dangling close brace } sits in this prose' '$R14/stacks/04_app/variables.tf'"
assert_true "heredoc terminator preserved" \
  "grep -qE '^  EOT$' '$R14/stacks/04_app/variables.tf'"
assert_true "block comment with braces preserved" \
  "grep -qF '/* config note: this resource uses { and } tokens */' '$R14/stacks/04_app/variables.tf'"

# =============================================================================
# Test 15: stacks are discovered independently of root.hcl, so an orphan stack
#   (not referenced by any root.hcl) is still checked for markers + outputs.
# =============================================================================
echo "TEST 15: orphan stack (no root.hcl) is still checked"
# given -- a repo with no environments/, just a stack
R15="$TEST_DIR/orphan"
mkdir -p "$R15/stacks/orphan"
cat > "$R15/stacks/orphan/variables.tf" << 'HCL'
variable "anything" {
  type = string
}
HCL
cat > "$R15/stacks/orphan/main.tf" << 'HCL'
module "alpha" {
  source = "./a"
}

module "beta" {
  source = "./b"
}
HCL
cat > "$R15/stacks/orphan/outputs.tf" << 'HCL'
output "b" {
  value = module.beta.id
}

output "a" {
  value = module.alpha.id
}
HCL
# when
set +e; OUT15="$(oc --repo-dir "$R15" 2>&1)"; RC15=$?; set -e
# then
assert_true "orphan stack variables.tf marker warning emitted" \
  "echo \"\$OUT15\" | grep -q 'stacks/orphan/variables.tf'"
assert_true "orphan stack outputs.tf ordering flagged (no root.hcl needed)" \
  "echo \"\$OUT15\" | grep -q 'stacks/orphan/outputs.tf'"
assert_true "outputs ordering is the failing error" "[ $RC15 -eq 1 ]"

# =============================================================================
# Test 16: check mode catches a dependency reference on a later line of a
#   multi-line input value (not just the assignment's first line).
# =============================================================================
echo "TEST 16: multi-line input value dependency reference is detected"
# given
R16="$TEST_DIR/multiline"
make_clean_repo "$R16"
cat > "$R16/environments/04_app/root.hcl" << 'HCL'
dependency "shared_common" {
  config_path = "${get_path_to_repo_root()}//environments/01_shared/02_common"
}

dependency "kubernetes" {
  config_path = "${get_path_to_repo_root()}//environments/03_kubernetes/x"
}

terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  kube = {
    host = dependency.kubernetes.outputs.host
  }

  registry = dependency.shared_common.outputs.registry
}
HCL
# when -- kubernetes(03) ref is on line 2 of kube's value, then
#         shared_common(01) follows: out of order, must be detected
set +e; OUT16="$(oc --repo-dir "$R16" 2>&1)"; set -e
# then
assert_true "multi-line input dependency ref is parsed and flagged" \
  "echo \"\$OUT16\" | grep -q 'root-hcl-inputs'"

# =============================================================================
# Test 17: an input in root.hcl not declared as a variable -> dead-code error.
# =============================================================================
echo "TEST 17: root.hcl input with no matching variable is flagged as dead"
# given -- a clean repo whose root.hcl passes one extra, undeclared input
R17="$TEST_DIR/dead-root"
make_clean_repo "$R17"
cat > "$R17/environments/04_app/root.hcl" << 'HCL'
dependency "shared_common" {
  config_path = "${get_path_to_repo_root()}//environments/01_shared/02_common"
}

dependency "kubernetes" {
  config_path = "${get_path_to_repo_root()}//environments/03_kubernetes/x"
}

terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  tags = local.tags

  registry = dependency.shared_common.outputs.registry

  kube = dependency.kubernetes.outputs.kube

  image = "app:1.0.0"

  orphan_input = "nothing in variables.tf declares me"
}
HCL
# when
set +e; OUT17="$(oc --repo-dir "$R17" 2>&1)"; RC17=$?; set -e
# then
assert_true "flags dead-inputs" "echo \"\$OUT17\" | grep -q 'dead-inputs'"
assert_true "names the undeclared key 'orphan_input'" \
  "echo \"\$OUT17\" | grep -q 'orphan_input'"
assert_true "points at the target stack in the message" \
  "echo \"\$OUT17\" | grep -q 'stacks/04_app'"
assert_true "does NOT blame a declared input ('registry')" \
  "! echo \"\$OUT17\" | grep -q 'registry'"
assert_true "dead input fails CI (exit 1)" "[ $RC17 -eq 1 ]"

# =============================================================================
# Test 18: an input in a leaf terragrunt.hcl not declared -> flagged on the leaf.
# =============================================================================
echo "TEST 18: leaf terragrunt.hcl input with no matching variable is flagged"
# given -- a per-instance leaf that includes root and adds an undeclared input
R18="$TEST_DIR/dead-leaf"
make_clean_repo "$R18"
mkdir -p "$R18/environments/04_app/prod/inst"
cat > "$R18/environments/04_app/prod/inst/terragrunt.hcl" << 'HCL'
include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  environment = "prod"
  ghost       = "declared nowhere in stacks/04_app"
}
HCL
# when -- the leaf inherits its stack (04_app) from the root it includes
set +e; OUT18="$(oc --repo-dir "$R18" 2>&1)"; RC18=$?; set -e
# then
assert_true "flags dead-inputs on the leaf file path" \
  "echo \"\$OUT18\" | grep -q 'environments/04_app/prod/inst/terragrunt.hcl'"
assert_true "names the undeclared leaf key 'ghost'" \
  "echo \"\$OUT18\" | grep -q 'ghost'"
assert_true "does NOT blame the declared leaf input 'environment'" \
  "! echo \"\$OUT18\" | grep -qE 'variable\\): .*environment'"
assert_true "leaf dead input fails CI (exit 1)" "[ $RC18 -eq 1 ]"

# =============================================================================
# Test 19: a leaf whose inputs are all declared is NOT flagged (no false pos).
# =============================================================================
echo "TEST 19: leaf with only declared inputs stays clean"
# given
R19="$TEST_DIR/live-leaf"
make_clean_repo "$R19"
mkdir -p "$R19/environments/04_app/prod/inst"
cat > "$R19/environments/04_app/prod/inst/terragrunt.hcl" << 'HCL'
include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  environment = "prod"
  image       = "app:2.0.0"
}
HCL
# when
set +e; OUT19="$(oc --repo-dir "$R19" 2>&1)"; RC19=$?; set -e
# then
assert_true "no dead-inputs finding for a fully-declared leaf" \
  "! echo \"\$OUT19\" | grep -q 'dead-inputs'"
assert_true "repo still passes (exit 0)" "[ $RC19 -eq 0 ]"

# =============================================================================
# Test 20: nested sub-stack resolution works; a container root.hcl is skipped.
#   environments/01_shared/02_common -> stacks/01_shared/02_common (path
#   convention, because the shared root.hcl's source is interpolated). The
#   container stacks/01_shared has no *.tf, so the shared root.hcl's own inputs
#   are conservatively skipped rather than mis-blamed on one sub-stack.
# =============================================================================
echo "TEST 20: nested sub-stack dead input flagged; container root skipped"
# given
R20="$TEST_DIR/nested"
mkdir -p "$R20/environments/01_shared/02_common" "$R20/stacks/01_shared/02_common"
cat > "$R20/environments/01_shared/root.hcl" << 'HCL'
terraform {
  source = "${get_path_to_repo_root()}//stacks/${basename(dirname(get_terragrunt_dir()))}/${basename(get_terragrunt_dir())}"
}

inputs = {
  tags = local.tags
}
HCL
cat > "$R20/environments/01_shared/02_common/terragrunt.hcl" << 'HCL'
include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  known        = "x"
  nested_ghost = "declared nowhere in stacks/01_shared/02_common"
}
HCL
cat > "$R20/stacks/01_shared/02_common/variables.tf" << 'HCL'
variable "known" {
  type = string
}
HCL
# when
set +e; OUT20="$(oc --repo-dir "$R20" 2>&1)"; RC20=$?; set -e
# then
assert_true "nested leaf resolves to stacks/01_shared/02_common and is flagged" \
  "echo \"\$OUT20\" | grep -q 'environments/01_shared/02_common/terragrunt.hcl'"
assert_true "names the undeclared nested key 'nested_ghost'" \
  "echo \"\$OUT20\" | grep -q 'nested_ghost'"
assert_true "container-level 01_shared/root.hcl is NOT reported (conservative)" \
  "! echo \"\$OUT20\" | grep -q '01_shared/root.hcl'"
assert_true "nested dead input fails CI (exit 1)" "[ $RC20 -eq 1 ]"

# =============================================================================
# Test 21: --fix never deletes a dead input (rule F is check-only).
# =============================================================================
echo "TEST 21: --fix reports but does not remove dead inputs"
# given -- same undeclared input as Test 17
R21="$TEST_DIR/dead-nofix"
make_clean_repo "$R21"
cat > "$R21/environments/04_app/root.hcl" << 'HCL'
terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  tags         = local.tags
  image        = "app:1.0.0"
  orphan_input = "still here after --fix"
}
HCL
# when
set +e; oc --repo-dir "$R21" --fix >/dev/null 2>&1; set -e
set +e; OUT21="$(oc --repo-dir "$R21" 2>&1)"; RC21=$?; set -e
# then
assert_true "dead input still present in the file after --fix" \
  "grep -q 'orphan_input' '$R21/environments/04_app/root.hcl'"
assert_true "still reported as dead after --fix" \
  "echo \"\$OUT21\" | grep -q 'dead-inputs'"
assert_true "still fails CI after --fix (exit 1)" "[ $RC21 -eq 1 ]"

# =============================================================================
# Test 22: a variable declared outside variables.tf still counts as declared.
# =============================================================================
echo "TEST 22: variable declared in another *.tf is not a false positive"
# given -- 'extra_var' is passed as an input and declared only in extra.tf
R22="$TEST_DIR/crossfile"
make_clean_repo "$R22"
cat > "$R22/environments/04_app/root.hcl" << 'HCL'
terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  tags      = local.tags
  image     = "app:1.0.0"
  extra_var = "declared in extra.tf, not variables.tf"
}
HCL
cat > "$R22/stacks/04_app/extra.tf" << 'HCL'
variable "extra_var" {
  type = string
}
HCL
# when
set +e; OUT22="$(oc --repo-dir "$R22" 2>&1)"; RC22=$?; set -e
# then
assert_true "cross-file variable is not flagged dead" \
  "! echo \"\$OUT22\" | grep -q 'dead-inputs'"
assert_true "repo passes (exit 0)" "[ $RC22 -eq 0 ]"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
