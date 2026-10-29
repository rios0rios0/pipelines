#!/usr/bin/env bash
# Validation script for Azure DevOps Go Lambda templates
# This script validates YAML syntax and template structure

set -euo pipefail

echo "=== Testing Azure DevOps Go Lambda Templates ==="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.." || exit 1

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# The checks are Go test support (`internal/testsuites/lambdatemplates`), built
# from this checkout for this run. A checker that does not build stops the
# suite: every check below would otherwise fail for a reason that has nothing
# to do with the templates.
TOOL_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TOOL_DIR"' EXIT
LAMBDA="$TOOL_DIR/lambdatemplates"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPT_DIR/../.." -trimpath -o "$LAMBDA" ./internal/testsuites/lambdatemplates; then
    echo -e "${RED}could not build ./internal/testsuites/lambdatemplates, so no check can run${NC}"
    exit 1
fi

# Function to print test results
print_result() {
    local result=$1
    local message=$2
    if [ $result -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        ((TESTS_FAILED++)) || true
    fi
}

# Test 1: Validate YAML syntax
echo "Test 1: Validating YAML syntax"
echo "================================"
TEST_RESULT=0
"$LAMBDA" syntax || TEST_RESULT=$?
print_result $TEST_RESULT "YAML syntax validation"

# Test 2: Validate template structure
echo ""
echo "Test 2: Validating template structure"
echo "======================================="
TEST_RESULT=0
"$LAMBDA" structure || TEST_RESULT=$?
print_result $TEST_RESULT "Template structure validation"

# Test 3: Validate parameter consistency
echo ""
echo "Test 3: Validating parameter consistency"
echo "=========================================="
TEST_RESULT=0
"$LAMBDA" parameters || TEST_RESULT=$?
print_result $TEST_RESULT "Parameter consistency validation"

# Test 4: Validate example configurations
echo ""
echo "Test 4: Validating example configurations"
echo "==========================================="
EXAMPLES_VALID=0

# Check template.yaml (SAM/CloudFormation templates use special tags like !Sub, !GetAtt)
if [ -f ".docs/examples/go-lambda-example/template.yaml" ]; then
    # Just check basic YAML structure and required keys
    if "$LAMBDA" sam .docs/examples/go-lambda-example/template.yaml; then
        echo "  ✓ template.yaml is valid SAM template"
    else
        echo "  ✗ template.yaml is invalid"
        EXAMPLES_VALID=1
    fi
else
    echo "  ✗ template.yaml not found"
    EXAMPLES_VALID=1
fi

# Check samconfig.toml
if [ -f ".docs/examples/go-lambda-example/samconfig.toml" ]; then
    # Basic check for TOML structure
    if grep -q "\[default\]" ".docs/examples/go-lambda-example/samconfig.toml"; then
        echo "  ✓ samconfig.toml has valid structure"
    else
        echo "  ✗ samconfig.toml missing [default] section"
        EXAMPLES_VALID=1
    fi
else
    echo "  ✗ samconfig.toml not found"
    EXAMPLES_VALID=1
fi

# Check azure-pipelines.yml
if [ -f ".docs/examples/go-lambda-example/azure-pipelines.yml" ]; then
    if "$LAMBDA" yaml .docs/examples/go-lambda-example/azure-pipelines.yml 2>/dev/null; then
        echo "  ✓ azure-pipelines.yml is valid"
    else
        echo "  ✗ azure-pipelines.yml is invalid"
        EXAMPLES_VALID=1
    fi
else
    echo "  ✗ azure-pipelines.yml not found"
    EXAMPLES_VALID=1
fi

# Check iam-policy-example.json
if [ -f ".docs/examples/go-lambda-example/iam-policy-example.json" ]; then
    if "$LAMBDA" json .docs/examples/go-lambda-example/iam-policy-example.json 2>/dev/null; then
        echo "  ✓ iam-policy-example.json is valid"
    else
        echo "  ✗ iam-policy-example.json is invalid"
        EXAMPLES_VALID=1
    fi
else
    echo "  ✗ iam-policy-example.json not found"
    EXAMPLES_VALID=1
fi

print_result $EXAMPLES_VALID "Example configurations validation"

# Test 5: Check documentation exists
echo ""
echo "Test 5: Checking documentation"
echo "================================"
DOC_VALID=0

if [ -f ".docs/azure-devops-go-lambda.md" ]; then
    # Check for key sections
    if grep -q "## Table of Contents" ".docs/azure-devops-go-lambda.md" && \
       grep -q "## IAM Permissions" ".docs/azure-devops-go-lambda.md" && \
       grep -q "## Examples" ".docs/azure-devops-go-lambda.md"; then
        echo "  ✓ azure-devops-go-lambda.md has all key sections"
    else
        echo "  ✗ azure-devops-go-lambda.md missing key sections"
        DOC_VALID=1
    fi
else
    echo "  ✗ azure-devops-go-lambda.md not found"
    DOC_VALID=1
fi

# Check README.md was updated
if grep -q "go-lambda.yaml" README.md && grep -q "go-lambda-sam.yaml" README.md; then
    echo "  ✓ README.md updated with new templates"
else
    echo "  ✗ README.md not updated with new templates"
    DOC_VALID=1
fi

print_result $DOC_VALID "Documentation validation"

# Print summary
echo ""
echo "===================================="
echo "Test Summary"
echo "===================================="
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
