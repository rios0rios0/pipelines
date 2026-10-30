#!/usr/bin/env bash
set -e

# Hold the Azure DevOps step-name contract across the whole repository.
#
# Why a dedicated regression test exists:
#
# Azure DevOps rejects a job whose expanded step list declares the same `name:`
# twice:
#
#   The step name Scripts appears more than once. Step names must be unique
#   within a job.
#
# It is a COMPILE-time error, so the job never starts -- nothing in it runs, and
# the failure is attributed to the job rather than to the template that caused
# it. Five abstracts here include `global/abstracts/scripts-repo.yaml`, whose
# step is `name: 'Scripts'`. A job that includes one of those abstracts AND
# includes `scripts-repo` directly therefore declares `Scripts` twice.
#
# That is easy to write and impossible to see: the second include reads as
# making a dependency explicit, both lines are individually correct, and neither
# file is wrong on its own -- the defect only exists in their COMBINATION, which
# no single file shows. It has already happened four times: `sca:govulncheck`
# on the Go template, then `style:tflint`, `test:all` and `test:validate` on the
# terra template.
#
# Nothing else in CI can catch it. The YAML is valid, ShellCheck does not read
# it, and this repository is a template library -- no pipeline here ever runs,
# so the first execution is always in a consumer's project. The templates must
# therefore be EXPANDED and checked here, which is what this test does.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPTS_DIR" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# assert_empty <description> <captured-output>
#
# Passes when the output is empty; the offending job is printed on failure, so
# the message names what to fix rather than only that something is wrong.
assert_empty() {
  local description="$1"
  local output="$2"
  if [ -z "$output" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    echo "$output" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# The expansion is shared by every assertion, so it runs once and each
# assertion selects its own findings. It is Go test support
# (`internal/testsuites/azurestepnames`), built from this checkout for this run;
# a checker that does not build stops the suite, because the assertions below
# would otherwise run against nothing and pass for it.
TOOL_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TOOL_DIR"' EXIT
EXPANDER="$TOOL_DIR/azurestepnames"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$EXPANDER" ./internal/testsuites/azurestepnames; then
  echo -e "${RED}could not build ./internal/testsuites/azurestepnames, so no assertion can run${NC}"
  exit 1
fi
# An expander that cannot read the templates prints nothing and exits 1; read as an empty
# expansion, every assertion below would pass for it.
EXPANSION="$("$EXPANDER")" || {
  echo -e "${RED}./internal/testsuites/azurestepnames could not expand the templates, so no assertion can run${NC}"
  exit 1
}

select_findings() {
  printf '%s\n' "$EXPANSION" | awk -F '\t' -v group="$1" '$1 == group { sub(/^[^\t]*\t/, ""); print }'
}

# Reported FIRST because it invalidates the two below: a template that does not
# parse, or an include that points at nothing, expands to no jobs -- so the
# assertions that follow would find nothing wrong and pass for the worst
# possible reason. This suite exists because nothing else can see these
# defects, which is exactly why it must not go quietly blind itself.
echo "1. Every Azure template parses and every include resolves"
UNREADABLE="$(select_findings unreadable)"
assert_empty "every template parses and every referenced include exists" "$UNREADABLE"
echo ""

echo "2. Step names are unique within every expanded job"
DUPLICATE_NAMES="$(select_findings duplicate)"
assert_empty "no job declares the same step name twice" "$DUPLICATE_NAMES"
echo ""

echo "3. Every job using \$(Scripts.Directory) checks the scripts out"
# The opposite failure, and the reason the duplicate is so tempting to add: a
# job that references $(Scripts.Directory) without including `scripts-repo`
# gets an EMPTY string, so the command becomes `/global/scripts/...` and the
# job fails with exit 127. That error names neither the variable nor the
# missing template, so the obvious fix -- add the include -- is exactly what
# creates the duplicate this file's first assertion catches. Both directions
# have to hold at once, which is why they are asserted together.
MISSING_SCRIPTS_REPO="$(select_findings scripts)"
assert_empty "every job using \$(Scripts.Directory) includes scripts-repo" "$MISSING_SCRIPTS_REPO"
echo ""

echo "=============================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ] && echo -e "${GREEN}Azure DevOps step-name contract holds${NC}"
[ "$TESTS_FAILED" -eq 0 ]
