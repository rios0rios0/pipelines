#!/usr/bin/env bash
# Validation script for Azure DevOps Go Lambda templates
# This script validates YAML syntax and template structure

set -euo pipefail

echo "=== Testing Azure DevOps Go Lambda Templates ==="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

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
python3 << 'EOF'
import yaml
import sys

files = [
    'azure-devops/golang/go-lambda.yaml',
    'azure-devops/golang/go-lambda-sam.yaml',
    'azure-devops/golang/stages/40-delivery/lambda.yaml',
    'azure-devops/golang/stages/50-deployment/lambda.yaml'
]

exit_code = 0
for file in files:
    try:
        with open(file, 'r') as f:
            yaml.safe_load(f)
        print(f'  ✓ {file}')
    except Exception as e:
        print(f'  ✗ {file}: {e}')
        exit_code = 1

sys.exit(exit_code)
EOF
TEST_RESULT=$?
print_result $TEST_RESULT "YAML syntax validation"

# Test 2: Validate template structure
echo ""
echo "Test 2: Validating template structure"
echo "======================================="
python3 << 'EOF'
import yaml
import sys

def validate_main_template(path, name):
    with open(path, 'r') as f:
        data = yaml.safe_load(f)
    
    errors = []
    
    # Check required keys
    if 'stages' not in data:
        errors.append(f"{name}: Missing 'stages' key")
    
    if 'parameters' not in data:
        errors.append(f"{name}: Missing 'parameters' key (expected for main templates)")
    
    # Check stages reference correct templates
    if 'stages' in data:
        for i, stage in enumerate(data['stages']):
            if isinstance(stage, dict) and 'template' in stage:
                template = stage['template']
                if not template.endswith('.yaml'):
                    errors.append(f"{name}: Stage {i+1} template doesn't end with .yaml")
    
    return errors

def validate_stage_template(path, name):
    with open(path, 'r') as f:
        data = yaml.safe_load(f)
    
    errors = []
    
    # Check required keys
    if 'stages' not in data and 'parameters' not in data:
        errors.append(f"{name}: Missing both 'stages' and 'parameters' keys")
    
    return errors

# Validate main templates
main_templates = {
    'go-lambda.yaml': 'azure-devops/golang/go-lambda.yaml',
    'go-lambda-sam.yaml': 'azure-devops/golang/go-lambda-sam.yaml'
}

all_errors = []
for name, path in main_templates.items():
    errors = validate_main_template(path, name)
    all_errors.extend(errors)
    if not errors:
        print(f'  ✓ {name}')

# Validate stage templates
stage_templates = {
    'delivery/lambda.yaml': 'azure-devops/golang/stages/40-delivery/lambda.yaml',
    'deployment/lambda.yaml': 'azure-devops/golang/stages/50-deployment/lambda.yaml'
}

for name, path in stage_templates.items():
    errors = validate_stage_template(path, name)
    all_errors.extend(errors)
    if not errors:
        print(f'  ✓ {name}')

if all_errors:
    print("\nErrors found:")
    for error in all_errors:
        print(f"  ✗ {error}")
    sys.exit(1)

sys.exit(0)
EOF
TEST_RESULT=$?
print_result $TEST_RESULT "Template structure validation"

# Test 3: Validate parameter consistency
echo ""
echo "Test 3: Validating parameter consistency"
echo "=========================================="
python3 << 'EOF'
import yaml
import re
import sys

def check_parameter_consistency(path, name):
    with open(path, 'r') as f:
        content = f.read()
        data = yaml.safe_load(content)
    
    errors = []
    warnings = []
    
    # Find all parameter references
    param_refs = re.findall(r'\$\{\{\s*parameters\.(\w+)\s*\}\}', content)
    
    if 'parameters' in data:
        defined_params = {p['name'] for p in data['parameters']}
        referenced_params = set(param_refs)
        
        # Check for undefined parameters being referenced
        undefined = referenced_params - defined_params
        if undefined:
            for param in undefined:
                errors.append(f"{name}: Parameter '{param}' referenced but not defined")
        
        # Check for unused parameters (warning only)
        unused = defined_params - referenced_params
        if unused:
            for param in unused:
                warnings.append(f"{name}: Parameter '{param}' defined but not used")
    
    return errors, warnings

main_templates = [
    ('go-lambda.yaml', 'azure-devops/golang/go-lambda.yaml'),
    ('go-lambda-sam.yaml', 'azure-devops/golang/go-lambda-sam.yaml')
]

all_errors = []
all_warnings = []

for name, path in main_templates:
    errors, warnings = check_parameter_consistency(path, name)
    all_errors.extend(errors)
    all_warnings.extend(warnings)
    if not errors and not warnings:
        print(f'  ✓ {name}')

if all_warnings:
    print("\nWarnings:")
    for warning in all_warnings:
        print(f"  ⚠ {warning}")

if all_errors:
    print("\nErrors:")
    for error in all_errors:
        print(f"  ✗ {error}")
    sys.exit(1)

sys.exit(0)
EOF
TEST_RESULT=$?
print_result $TEST_RESULT "Parameter consistency validation"

# Test 4: Validate example configurations
echo ""
echo "Test 4: Validating example configurations"
echo "==========================================="
EXAMPLES_VALID=0

# Check template.yaml (SAM/CloudFormation templates use special tags like !Sub, !GetAtt)
if [ -f ".docs/examples/go-lambda-example/template.yaml" ]; then
    # Just check basic YAML structure and required keys
    python3 << 'PYEOF'
import yaml
import sys

# Add constructors for CloudFormation intrinsic functions
def cloudformation_constructor(loader, tag_suffix, node):
    return loader.construct_scalar(node)

yaml.SafeLoader.add_multi_constructor('!', cloudformation_constructor)

try:
    with open('.docs/examples/go-lambda-example/template.yaml', 'r') as f:
        data = yaml.safe_load(f)
    
    # Check for required SAM template keys
    if 'AWSTemplateFormatVersion' in data and 'Transform' in data and 'Resources' in data:
        sys.exit(0)
    else:
        sys.exit(1)
except Exception as e:
    sys.exit(1)
PYEOF
    if [ $? -eq 0 ]; then
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
    python3 -c "import yaml; yaml.safe_load(open('.docs/examples/go-lambda-example/azure-pipelines.yml'))" 2>/dev/null
    if [ $? -eq 0 ]; then
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
    python3 -c "import json; json.load(open('.docs/examples/go-lambda-example/iam-policy-example.json'))" 2>/dev/null
    if [ $? -eq 0 ]; then
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
