#!/usr/bin/env bash
set -e

# Test script for validating the Terraform generic coverage report generator.
# Exercises terra_coverage.py against synthetic module trees and asserts the
# emitted SonarQube generic-coverage XML measures what it claims to.
#
# Every numbered case below is a regression guard for a defect a regex
# prototype hit on real repositories -- the comments name which.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COV="$SCRIPTS_DIR/global/scripts/languages/terraform/terra-test/terra_coverage.py"
TEST_DIR="$(mktemp -d)" || exit 1

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
# Test 1: Root-layout module, reached through locals and outputs
#   (regression guard: the prototype walked modules/ with rglob("*"), which
#    never yields the root itself, so a module published as its own repo
#    scored 0/0 instead of being measured. And a block reachable only through
#    `local.x` or `output.x` read as uncovered -- smoke tests assert on
#    outputs almost exclusively, so that lost nearly every real hit.)
# =============================================================================
echo "TEST 1: Root-layout module + locals/output indirection"
# given -- no modules/ dir; the repo root IS the module, tests/ beside it
REPO1="$TEST_DIR/repo1"
mkdir -p "$REPO1/tests"
cat > "$REPO1/main.tf" << 'HCL'
locals {
  name      = "demo"
  bucket_id = aws_s3_bucket.logs.id
}

resource "aws_s3_bucket" "logs" {
  bucket = local.name
}

resource "aws_s3_bucket" "unused" {
  bucket = "nope"
}

output "bucket_id" {
  value = local.bucket_id
}
HCL
cat > "$REPO1/tests/smoke.tftest.hcl" << 'HCL'
run "smoke" {
  command = plan
  assert {
    condition     = output.bucket_id != ""
    error_message = "no id"
  }
}
HCL

# when
OUT1="$REPO1/out1.xml"
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY1="$(python3 "$COV" --repo-dir "$REPO1" --output "$OUT1")"

# then
assert_true "root-layout module is measured, not scored 0/0" \
  "echo \"\$SUMMARY1\" | grep -q 'terra generic coverage: 2/3 blocks (66%)'"
assert_true "emitted XML parses" \
  "python3 -c 'import xml.etree.ElementTree as ET; ET.parse(\"$OUT1\")'"
assert_true "root element is <coverage version=\"1\">" \
  "python3 -c 'import xml.etree.ElementTree as ET; r=ET.parse(\"$OUT1\").getroot(); raise SystemExit(0 if r.tag==\"coverage\" and r.get(\"version\")==\"1\" else 1)'"
assert_true "path is relative to --repo-dir" \
  "grep -q '<file path=\"main.tf\">' '$OUT1'"
assert_true "block reached only through local.* is covered" \
  "grep -q '<lineToCover lineNumber=\"6\" covered=\"true\"/>' '$OUT1'"
assert_true "block nothing references is uncovered" \
  "grep -q '<lineToCover lineNumber=\"10\" covered=\"false\"/>' '$OUT1'"
assert_true "output asserted on directly is covered" \
  "grep -q '<lineToCover lineNumber=\"14\" covered=\"true\"/>' '$OUT1'"
assert_true "one lineToCover per block, not per source line" \
  "[ \"\$(grep -c '<lineToCover ' '$OUT1')\" -eq 3 ]"
assert_true "granularity caveat is stated on stdout" \
  "echo \"\$SUMMARY1\" | grep -q 'granularity is per BLOCK, not per line'"
assert_true "granularity caveat is stated in the XML header" \
  "grep -q 'CAVEAT, BLOCK GRANULARITY' '$OUT1'"

# =============================================================================
# Test 2: modules/ layout -- behavioural seeds, balanced scan, vendored prune
#   (regression guards, three at once:
#    * expect_failures / precondition / postcondition / check all scored zero,
#      discarding real behavioural tests -- one of them the guard protecting
#      against an outage that took a fleet down;
#    * a non-greedy assert-body regex truncated at the first nested `}`, so
#      every reference after it vanished. The condition below is the real one
#      from customer-clusters/modules/aws_aurora that it truncated;
#    * .terraform / .terragrunt-cache copies and tests/ code inflated the
#      denominator and duplicated the successes.)
# =============================================================================
echo "TEST 2: modules/ layout -- behavioural seeds, balanced scan, pruning"
# given
REPO2="$TEST_DIR/repo2"
mkdir -p "$REPO2/modules/aurora/tests" \
         "$REPO2/modules/aurora/.terraform/modules/vendored" \
         "$REPO2/modules/aurora/.terragrunt-cache/xyz" \
         "$REPO2/modules/notests"
cat > "$REPO2/modules/aurora/main.tf" << 'HCL'
resource "aws_rds_cluster_parameter_group" "main" {
  name = "pg"
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = "c"

  lifecycle {
    precondition {
      condition     = var.size > 0
      error_message = "size"
    }
  }
}

resource "aws_rds_cluster_instance" "replica" {
  identifier = "i"

  lifecycle {
    postcondition {
      condition     = self.id != ""
      error_message = "id"
    }
  }
}

check "health" {
  assert {
    condition     = aws_rds_cluster.main.endpoint != ""
    error_message = "endpoint"
  }
}

resource "aws_kms_key" "orphan" {
  description = "aws_rds_cluster.main /* not a ref */ and https://x.example/#y"
}

resource "aws_db_subnet_group" "main" {
  name = "sng"
}
HCL
cat > "$REPO2/modules/aurora/tests/smoke.tftest.hcl" << 'HCL'
run "smoke" {
  command = plan

  # mentions aws_kms_key.orphan -- a comment must never create a reference
  assert {
    condition     = length([for p in aws_rds_cluster_parameter_group.main.parameter : p if p.name == "shared_preload_libraries" && p.value == "pg_stat_statements,pgaudit" && p.apply_method == "pending-reboot"]) == 1
    error_message = "params"
  }

  assert {
    condition     = length("aws_kms_key.orphan") > 0
    error_message = "a literal mention must not count"
  }
}

run "guard" {
  command = plan

  expect_failures = [
    aws_db_subnet_group.main,
  ]
}
HCL
# test-only code, and two vendored copies of real modules
cat > "$REPO2/modules/aurora/tests/helper.tf" << 'HCL'
resource "aws_iam_role" "test_only" {
  name = "t"
}
HCL
cat > "$REPO2/modules/aurora/.terraform/modules/vendored/main.tf" << 'HCL'
resource "aws_s3_bucket" "vendored_a" { bucket = "a" }
resource "aws_s3_bucket" "vendored_b" { bucket = "b" }
HCL
cp "$REPO2/modules/aurora/.terraform/modules/vendored/main.tf" \
   "$REPO2/modules/aurora/.terragrunt-cache/xyz/main.tf"
cat > "$REPO2/modules/notests/main.tf" << 'HCL'
resource "aws_sns_topic" "alerts" {
  name = "a"
}
HCL

# when
OUT2="$REPO2/out2.xml"
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY2="$(python3 "$COV" --repo-dir "$REPO2" --output "$OUT2")"

# then
assert_true "denominator excludes vendored and test code (5/7, not 5/12)" \
  "echo \"\$SUMMARY2\" | grep -q 'terra generic coverage: 5/7 blocks'"
assert_true ".terraform copies are not reported" \
  "! grep -q '\.terraform' '$OUT2'"
assert_true ".terragrunt-cache copies are not reported" \
  "! grep -q 'terragrunt-cache' '$OUT2'"
assert_true "code under tests/ is not in the denominator" \
  "! grep -q 'tests/helper.tf' '$OUT2'"
assert_true "balanced scan keeps the reference inside a nested for-expression" \
  "grep -q '<lineToCover lineNumber=\"1\" covered=\"true\"/>' '$OUT2'"
assert_true "lifecycle precondition covers its containing block" \
  "grep -q '<lineToCover lineNumber=\"5\" covered=\"true\"/>' '$OUT2'"
assert_true "lifecycle postcondition covers its containing block" \
  "grep -q '<lineToCover lineNumber=\"16\" covered=\"true\"/>' '$OUT2'"
assert_true "check block with an assert is covered" \
  "grep -q '<lineToCover lineNumber=\"27\" covered=\"true\"/>' '$OUT2'"
assert_true "expect_failures entry covers the address it names" \
  "grep -q '<lineToCover lineNumber=\"38\" covered=\"true\"/>' '$OUT2'"
assert_true "a mention in a comment or a string literal does not cover" \
  "grep -q '<lineToCover lineNumber=\"34\" covered=\"false\"/>' '$OUT2'"
assert_true "a module with no .tftest.hcl is entirely uncovered" \
  "grep -A1 'modules/notests/main.tf' '$OUT2' | grep -q 'covered=\"false\"'"
assert_true "line numbers are ascending within a file" \
  "python3 -c 'import xml.etree.ElementTree as ET; f=ET.parse(\"$OUT2\").getroot()[0]; n=[int(l.get(\"lineNumber\")) for l in f]; raise SystemExit(0 if n==sorted(set(n)) else 1)'"

# =============================================================================
# Test 3: Heredoc bodies are not code, but their interpolations are references
# =============================================================================
echo "TEST 3: Heredoc masking keeps \${...} references, drops the body text"
# given
REPO3="$TEST_DIR/repo3"
mkdir -p "$REPO3/tests"
cat > "$REPO3/main.tf" << 'HCL'
locals {
  policy = <<-EOT
    { "Resource": "${aws_s3_bucket.logs.arn}" }
    aws_kms_key.not_a_ref
  EOT
}

resource "aws_s3_bucket" "logs" {
  bucket = "l"
}

resource "aws_kms_key" "not_a_ref" {
  description = "d"
}

output "p" {
  value = local.policy
}
HCL
cat > "$REPO3/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  assert {
    condition     = output.p != ""
    error_message = "x"
  }
}
HCL

# when
OUT3="$REPO3/out3.xml"
python3 "$COV" --repo-dir "$REPO3" --output "$OUT3" --quiet

# then
assert_true "--quiet prints nothing" \
  "[ -z \"\$(python3 '$COV' --repo-dir '$REPO3' --output '$OUT3' --quiet)\" ]"
assert_true "a brace inside a heredoc does not end the locals block" \
  "[ \"\$(grep -c '<lineToCover ' '$OUT3')\" -eq 3 ]"
assert_true "interpolated reference inside a heredoc is a real reference" \
  "grep -q '<lineToCover lineNumber=\"8\" covered=\"true\"/>' '$OUT3'"
assert_true "plain heredoc body text is not a reference" \
  "grep -q '<lineToCover lineNumber=\"12\" covered=\"false\"/>' '$OUT3'"

# =============================================================================
# Test 4: Nothing to measure -- still a valid document, still exit 0
#   (this tier reports, it must never break CI)
# =============================================================================
echo "TEST 4: Empty tree yields a valid empty document and exit 0"
# given
REPO4="$TEST_DIR/repo4"
mkdir -p "$REPO4"

# when
OUT4="$REPO4/nested/dir/out4.xml"
set +e
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY4="$(python3 "$COV" --repo-dir "$REPO4" --output "$OUT4")"
EXIT4=$?
set -e

# then
assert_true "exit status is 0 with nothing to measure" "[ $EXIT4 -eq 0 ]"
assert_true "output parent directory is created" "[ -f '$OUT4' ]"
assert_true "empty report still parses as XML" \
  "python3 -c 'import xml.etree.ElementTree as ET; r=ET.parse(\"$OUT4\").getroot(); raise SystemExit(0 if r.tag==\"coverage\" and r.get(\"version\")==\"1\" and len(r)==0 else 1)'"
assert_true "empty run says so on stdout" \
  "echo \"\$SUMMARY4\" | grep -q 'nothing to measure'"
assert_true "empty run still states the granularity caveat" \
  "echo \"\$SUMMARY4\" | grep -q 'granularity is per BLOCK'"

# =============================================================================
# Test 5: An examples/ tree is usage of the module, not module code
#   (regression guard: the walk pruned only vendored trees, so in the root
#    layout -- the common published-module layout -- every block under
#    `examples/` landed in the denominator and deflated the module that ships
#    them.)
# =============================================================================
echo "TEST 5: examples/ is excluded from the denominator"
# given -- a root-layout module that ships an examples/ tree
REPO5="$TEST_DIR/repo5"
mkdir -p "$REPO5/tests" "$REPO5/examples/complete"
cat > "$REPO5/main.tf" << 'HCL'
resource "aws_s3_bucket" "logs" {
  bucket = "l"
}

output "bucket_id" {
  value = aws_s3_bucket.logs.id
}
HCL
cat > "$REPO5/examples/complete/main.tf" << 'HCL'
module "example" {
  source = "../.."
}

resource "aws_s3_bucket" "example_only" {
  bucket = "e"
}
HCL
cat > "$REPO5/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  command = plan
  assert {
    condition     = output.bucket_id != ""
    error_message = "no id"
  }
}
HCL

# when
OUT5="$REPO5/out5.xml"
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY5="$(python3 "$COV" --repo-dir "$REPO5" --output "$OUT5")"

# then
assert_true "example usage is not module code (2/2, not 2/4)" \
  "echo \"\$SUMMARY5\" | grep -q 'terra generic coverage: 2/2 blocks'"
assert_true "no examples/ path is reported at all" \
  "! grep -q 'examples' '$OUT5'"

# =============================================================================
# Test 6: An address is unique per directory, not per module scan
#   (regression guard: addresses were global to the whole module scan, so two
#    nested submodules each declaring `aws_s3_bucket.this` shared ONE coverage
#    entry and the asserted one marked the unasserted one covered.)
# =============================================================================
echo "TEST 6: the same address in two nested directories does not collide"
# given -- two nested submodules declaring the identical address, one asserted
REPO6="$TEST_DIR/repo6"
mkdir -p "$REPO6/tests" "$REPO6/internal/alpha" "$REPO6/internal/beta"
cat > "$REPO6/main.tf" << 'HCL'
module "alpha" {
  source = "./internal/alpha"
}
HCL
cat > "$REPO6/internal/alpha/main.tf" << 'HCL'
resource "aws_s3_bucket" "this" {
  bucket = "a"
}

check "alpha_named" {
  assert {
    condition     = aws_s3_bucket.this.arn != ""
    error_message = "arn"
  }
}
HCL
cat > "$REPO6/internal/beta/main.tf" << 'HCL'
resource "aws_s3_bucket" "this" {
  bucket = "b"
}
HCL
cat > "$REPO6/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  command = plan
  assert {
    condition     = module.alpha != null
    error_message = "x"
  }
}
HCL

# when
OUT6="$REPO6/out6.xml"
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY6="$(python3 "$COV" --repo-dir "$REPO6" --output "$OUT6")"

# then
assert_true "only the asserted submodule is credited (3/4, not 4/4)" \
  "echo \"\$SUMMARY6\" | grep -q 'terra generic coverage: 3/4 blocks'"
assert_true "the submodule whose own check names the address is covered" \
  "[ \"\$(grep -A2 'internal/alpha/main.tf' '$OUT6' | grep -c 'covered=\"true\"')\" -eq 2 ]"
assert_true "the sibling declaring the same address is NOT covered by it" \
  "grep -A1 'internal/beta/main.tf' '$OUT6' | grep -q '<lineToCover lineNumber=\"1\" covered=\"false\"/>'"

# =============================================================================
# Test 7: Only the test files `run.sh` selects may credit coverage
#   (regression guard: discovery walked tests/ recursively, so a
#    `tests/e2e/*.tftest.hcl` the terra-test tier never executes -- its selector
#    is `ls "${mod}"/tests/*.tftest.hcl` -- credited coverage for a test that
#    did not run.)
# =============================================================================
echo "TEST 7: only tests/*.tftest.hcl counts, matching run.sh's glob"
# given -- one selected test file, one nested under tests/e2e, one in the root
REPO7="$TEST_DIR/repo7"
mkdir -p "$REPO7/tests/e2e"
cat > "$REPO7/main.tf" << 'HCL'
resource "aws_s3_bucket" "shallow" {
  bucket = "s"
}

resource "aws_s3_bucket" "deep_only" {
  bucket = "d"
}

resource "aws_s3_bucket" "root_test_only" {
  bucket = "r"
}
HCL
cat > "$REPO7/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  command = plan
  assert {
    condition     = aws_s3_bucket.shallow.id != ""
    error_message = "shallow"
  }
}
HCL
cat > "$REPO7/tests/e2e/deep.tftest.hcl" << 'HCL'
run "deep" {
  command = plan
  assert {
    condition     = aws_s3_bucket.deep_only.id != ""
    error_message = "deep"
  }
}
HCL
cat > "$REPO7/root.tftest.hcl" << 'HCL'
run "root" {
  command = plan
  assert {
    condition     = aws_s3_bucket.root_test_only.id != ""
    error_message = "root"
  }
}
HCL

# when
OUT7="$REPO7/out7.xml"
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY7="$(python3 "$COV" --repo-dir "$REPO7" --output "$OUT7")"

# then
assert_true "only the executed test credits coverage (1/3, not 3/3)" \
  "echo \"\$SUMMARY7\" | grep -q 'terra generic coverage: 1/3 blocks'"
assert_true "the assertion run.sh selects covers its block" \
  "grep -q '<lineToCover lineNumber=\"1\" covered=\"true\"/>' '$OUT7'"
assert_true "a tests/e2e assertion the tier never runs covers nothing" \
  "grep -q '<lineToCover lineNumber=\"5\" covered=\"false\"/>' '$OUT7'"
assert_true "a *.tftest.hcl in the module root covers nothing either" \
  "grep -q '<lineToCover lineNumber=\"9\" covered=\"false\"/>' '$OUT7'"

# =============================================================================
# Test 8: `examples` prunes the file walk, never module discovery
#   (regression guard: both consumers shared one set, so a module legitimately
#    named `modules/examples/` was silently skipped and scored nothing at all
#    -- the same invisibility the root-layout case in Test 1 exists to fix.
#    Pruning it from the walk INSIDE a module must keep working.)
# =============================================================================
echo "TEST 8: modules/examples/ is a module; a module's examples/ is not code"
# given -- a module actually named examples, and a sibling shipping examples/
REPO8="$TEST_DIR/repo8"
mkdir -p "$REPO8/modules/examples/tests" "$REPO8/modules/alpha/tests" \
  "$REPO8/modules/alpha/examples/complete"
cat > "$REPO8/modules/examples/main.tf" << 'HCL'
resource "aws_s3_bucket" "measured" {
  bucket = "m"
}
HCL
cat > "$REPO8/modules/examples/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  command = plan
  assert {
    condition     = aws_s3_bucket.measured.id != ""
    error_message = "measured"
  }
}
HCL
cat > "$REPO8/modules/alpha/main.tf" << 'HCL'
resource "aws_s3_bucket" "alpha" {
  bucket = "a"
}
HCL
cat > "$REPO8/modules/alpha/examples/complete/main.tf" << 'HCL'
resource "aws_s3_bucket" "example_only" {
  bucket = "e"
}
HCL
cat > "$REPO8/modules/alpha/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  command = plan
  assert {
    condition     = aws_s3_bucket.alpha.id != ""
    error_message = "alpha"
  }
}
HCL

# when
OUT8="$REPO8/out8.xml"
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY8="$(python3 "$COV" --repo-dir "$REPO8" --output "$OUT8")"

# then
assert_true "a module named examples is measured, not skipped (2/2, not 1/1)" \
  "echo \"\$SUMMARY8\" | grep -q 'terra generic coverage: 2/2 blocks'"
assert_true "modules/examples/ reports its own blocks" \
  "grep -q 'path=\"modules/examples/main.tf\"' '$OUT8'"
assert_true "examples/ inside a module stays out of its denominator" \
  "! grep -q 'modules/alpha/examples' '$OUT8'"

# =============================================================================
# Test 9: A quote inside ${...} does not end the string literal
# =============================================================================
echo "TEST 9: Nested quotes inside an interpolation keep their references"
# given
# `"${join(",", [...])}"` is the common shape, and ending the literal at the
# separator would blank the rest and lose the reference after it -- the block
# would read as uncovered on the strength of its punctuation alone.
REPO9="$TEST_DIR/repo9"
mkdir -p "$REPO9/modules/m/tests"
cat > "$REPO9/modules/m/main.tf" << 'HCL'
resource "null_resource" "via_plain" {
  triggers = { x = "1" }
}

resource "null_resource" "via_nested" {
  triggers = { x = "2" }
}

output "plain_out" {
  value = join("-", [null_resource.via_plain.id])
}

output "nested_out" {
  value = "${join(",", [null_resource.via_nested.id])}"
}
HCL
cat > "$REPO9/modules/m/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  assert {
    condition     = output.plain_out != "" && output.nested_out != ""
    error_message = "x"
  }
}
HCL

# when
OUT9="$REPO9/out9.xml"
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
SUMMARY9="$(python3 "$COV" --repo-dir "$REPO9" --output "$OUT9")"

# then
assert_true "every block is reached, including through the nested quotes (4/4)" \
  "echo \"\$SUMMARY9\" | grep -q 'terra generic coverage: 4/4 blocks'"
assert_true "the block reached only through \${...} with nested quotes is covered" \
  "grep -q '<lineToCover lineNumber=\"5\" covered=\"true\"/>' '$OUT9'"

# =============================================================================
# Test 10: --output cannot escape the repository being measured
# =============================================================================
echo "TEST 10: A traversing --output is refused, not followed"
# given
# The report describes the repository it measured, so it belongs inside it.
# Following a `..` would also create the directories on the way, which is a
# path traversal for any caller that does not choose its own arguments.
REPO10="$TEST_DIR/repo10"
OUTSIDE10="$TEST_DIR/outside10"
mkdir -p "$REPO10/modules/m/tests" "$OUTSIDE10"
cat > "$REPO10/modules/m/main.tf" << 'HCL'
resource "null_resource" "a" {
  triggers = { x = "1" }
}
HCL
cat > "$REPO10/modules/m/tests/smoke.tftest.hcl" << 'HCL'
run "r" {
  assert {
    condition     = 1 == 1
    error_message = "x"
  }
}
HCL

# when
set +e
TRAVERSE10="$(python3 "$COV" --repo-dir "$REPO10" --output "$REPO10/../outside10/escaped.xml" --quiet 2>&1)"
TRAVERSE10_RC=$?
set -e
# shellcheck disable=SC2034  # used inside assert_true's eval'd argument
TRAVERSE10_OUT="$TRAVERSE10"

# then
assert_true "a traversing --output exits non-zero" \
  "[[ $TRAVERSE10_RC -ne 0 ]]"
assert_true "it says why, naming the repository it is confined to" \
  "echo \"\$TRAVERSE10_OUT\" | grep -q 'must stay inside'"
assert_true "nothing is written outside the repository" \
  "[[ ! -e '$OUTSIDE10/escaped.xml' ]]"
assert_true "a relative --output still resolves inside the repository" \
  "python3 '$COV' --repo-dir '$REPO10' --output build/reports/in.xml --quiet && [[ -s '$REPO10/build/reports/in.xml' ]]"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
