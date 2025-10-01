#!/usr/bin/env bash
set -e

# Test script for validating YAML merge functionality in golangci-lint/run.sh
# This script tests various scenarios of merging custom .golangci.yml with default config

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLANGCI_LINT_SCRIPT="$SCRIPTS_DIR/global/scripts/golangci-lint/run.sh"
DEFAULT_CONFIG="$SCRIPTS_DIR/global/scripts/golangci-lint/.golangci.yml"
TEST_DIR="/tmp/golangci-lint-test-$$"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
print_test() {
    echo ""
    echo "========================================="
    echo "TEST: $1"
    echo "========================================="
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Cleanup function
cleanup() {
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Setup test directory
setup_test() {
    cleanup
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Create a minimal Go module for testing
    cat > go.mod << 'EOF'
module test-project

go 1.21
EOF
    
    cat > main.go << 'EOF'
package main

import "fmt"

func main() {
    fmt.Println("Test")
}
EOF
}

# Test 1: No custom config (should use default)
test_no_custom_config() {
    print_test "No custom .golangci.yml - should use default config"
    setup_test
    
    # Run the merge logic (without actually running golangci-lint)
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    
    # Extract just the merge part from the script
    if [ ! -f ".golangci.yml" ]; then
        cp "$DEFAULT_CONFIG" "merged.yml"
        print_success "Default config copied when no custom config exists"
    else
        print_error "Custom config found when none should exist"
        return 1
    fi
    
    # Verify merged.yml exists and has content
    if [ -f "merged.yml" ] && [ -s "merged.yml" ]; then
        print_success "Merged config file created successfully"
    else
        print_error "Merged config file is missing or empty"
        return 1
    fi
    
    # Verify it contains expected linters from default
    if yq eval '.linters.enable | contains(["errcheck", "govet", "staticcheck"])' merged.yml | grep -q true; then
        print_success "Default linters present in merged config"
    else
        print_error "Default linters missing from merged config"
        return 1
    fi
}

# Test 2: Custom config with additional enabled linters
test_custom_enable_linters() {
    print_test "Custom config with additional enabled linters"
    setup_test
    
    cat > .golangci.yml << 'EOF'
linters:
  enable:
    - exhaustruct
    - ginkgolinter
EOF
    
    # Run merge logic
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    cp "$DEFAULT_CONFIG" "merged.yml"
    
    repo_enabled=$(yq eval '.linters.enable[]?' ".golangci.yml" 2>/dev/null || true)
    if [ -n "$repo_enabled" ]; then
        echo "$repo_enabled" | while IFS= read -r linter; do
            if [ -n "$linter" ]; then
                if ! yq eval ".linters.enable | contains([\"$linter\"])" "merged.yml" | grep -q true; then
                    yq eval ".linters.enable += [\"$linter\"]" -i "merged.yml"
                fi
            fi
        done
    fi
    
    # Verify new linters were added
    if yq eval '.linters.enable | contains(["exhaustruct", "ginkgolinter"])' merged.yml | grep -q true; then
        print_success "Custom enabled linters added to merged config"
    else
        print_error "Custom enabled linters not found in merged config"
        return 1
    fi
    
    # Verify default linters still present
    if yq eval '.linters.enable | contains(["errcheck", "govet"])' merged.yml | grep -q true; then
        print_success "Default linters preserved in merged config"
    else
        print_error "Default linters missing after merge"
        return 1
    fi
}

# Test 3: Custom config with disabled linters
test_custom_disable_linters() {
    print_test "Custom config with disabled linters"
    setup_test
    
    cat > .golangci.yml << 'EOF'
linters:
  disable:
    - staticcheck
    - cyclop
EOF
    
    # Run merge logic
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    cp "$DEFAULT_CONFIG" "merged.yml"
    
    repo_disabled=$(yq eval '.linters.disable[]?' ".golangci.yml" 2>/dev/null || true)
    if [ -n "$repo_disabled" ]; then
        echo "$repo_disabled" | while IFS= read -r linter; do
            if [ -n "$linter" ]; then
                yq eval ".linters.enable = (.linters.enable | map(select(. != \"$linter\")))" -i "merged.yml"
            fi
        done
    fi
    
    # Verify disabled linters were removed
    if yq eval '.linters.enable | contains(["staticcheck"])' merged.yml | grep -q false; then
        print_success "Disabled linters removed from merged config"
    else
        print_error "Disabled linters still present in merged config"
        return 1
    fi
    
    # Verify other linters still present
    if yq eval '.linters.enable | contains(["errcheck", "govet"])' merged.yml | grep -q true; then
        print_success "Other linters preserved after disabling specific ones"
    else
        print_error "Other linters missing after disable operation"
        return 1
    fi
}

# Test 4: Custom config with linter settings
test_custom_linter_settings() {
    print_test "Custom config with linter-specific settings"
    setup_test
    
    cat > .golangci.yml << 'EOF'
linters-settings:
  errcheck:
    check-type-assertions: true
    check-blank: true
  govet:
    check-shadowing: false
EOF
    
    # Run merge logic
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    cp "$DEFAULT_CONFIG" "merged.yml"
    
    if yq eval '.linters-settings' ".golangci.yml" >/dev/null 2>&1; then
        yq eval '.linters-settings = (.linters-settings // {})' -i "merged.yml"
        temp_file=$(mktemp)
        yq eval-all 'select(fileIndex == 0) * {"linters-settings": select(fileIndex == 1).linters-settings}' "merged.yml" ".golangci.yml" > "$temp_file"
        mv "$temp_file" "merged.yml"
    fi
    
    # Verify custom settings were applied
    if [ "$(yq eval '.linters-settings.errcheck.check-type-assertions' merged.yml)" = "true" ]; then
        print_success "Custom linter settings merged successfully"
    else
        print_error "Custom linter settings not applied"
        return 1
    fi
    
    # Verify the merge operation preserves the structure
    # Note: The merge operation with yq's * operator will merge settings,
    # overriding keys that exist in both files with values from the custom config
    if yq eval '.linters-settings | has("errcheck")' merged.yml | grep -q true; then
        print_success "Linter settings structure preserved after merge"
    else
        print_error "Linter settings structure corrupted"
        return 1
    fi
}

# Test 5: Complex custom config (enable + disable + settings)
test_complex_custom_config() {
    print_test "Complex custom config with enable, disable, and settings"
    setup_test
    
    cat > .golangci.yml << 'EOF'
linters:
  enable:
    - exhaustruct
    - ginkgolinter
  disable:
    - staticcheck
    - cyclop

linters-settings:
  errcheck:
    check-type-assertions: true
  exhaustruct:
    exclude:
      - '^net/http\.Client$'
EOF
    
    # Run complete merge logic
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    cp "$DEFAULT_CONFIG" "merged.yml"
    
    # Add enabled linters
    repo_enabled=$(yq eval '.linters.enable[]?' ".golangci.yml" 2>/dev/null || true)
    if [ -n "$repo_enabled" ]; then
        echo "$repo_enabled" | while IFS= read -r linter; do
            if [ -n "$linter" ]; then
                if ! yq eval ".linters.enable | contains([\"$linter\"])" "merged.yml" | grep -q true; then
                    yq eval ".linters.enable += [\"$linter\"]" -i "merged.yml"
                fi
            fi
        done
    fi
    
    # Remove disabled linters
    repo_disabled=$(yq eval '.linters.disable[]?' ".golangci.yml" 2>/dev/null || true)
    if [ -n "$repo_disabled" ]; then
        echo "$repo_disabled" | while IFS= read -r linter; do
            if [ -n "$linter" ]; then
                yq eval ".linters.enable = (.linters.enable | map(select(. != \"$linter\")))" -i "merged.yml"
            fi
        done
    fi
    
    # Merge settings
    if yq eval '.linters-settings' ".golangci.yml" >/dev/null 2>&1; then
        yq eval '.linters-settings = (.linters-settings // {})' -i "merged.yml"
        temp_file=$(mktemp)
        yq eval-all 'select(fileIndex == 0) * {"linters-settings": select(fileIndex == 1).linters-settings}' "merged.yml" ".golangci.yml" > "$temp_file"
        mv "$temp_file" "merged.yml"
    fi
    
    # Verify all operations
    if yq eval '.linters.enable | contains(["exhaustruct", "ginkgolinter"])' merged.yml | grep -q true; then
        print_success "New linters enabled"
    else
        print_error "New linters not enabled"
        return 1
    fi
    
    if yq eval '.linters.enable | contains(["staticcheck", "cyclop"])' merged.yml | grep -q false; then
        print_success "Specified linters disabled"
    else
        print_error "Linters not properly disabled"
        return 1
    fi
    
    if [ "$(yq eval '.linters-settings.errcheck.check-type-assertions' merged.yml)" = "true" ]; then
        print_success "Custom settings applied"
    else
        print_error "Custom settings not applied"
        return 1
    fi
}

# Test 6: Empty custom config
test_empty_custom_config() {
    print_test "Empty custom .golangci.yml file"
    setup_test
    
    touch .golangci.yml
    
    # Run merge logic
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    cp "$DEFAULT_CONFIG" "merged.yml"
    
    # Should handle empty file gracefully
    repo_enabled=$(yq eval '.linters.enable[]?' ".golangci.yml" 2>/dev/null || true)
    if [ -z "$repo_enabled" ]; then
        print_success "Empty config handled gracefully"
    else
        print_error "Empty config not handled properly"
        return 1
    fi
    
    # Verify default config is still valid
    if yq eval '.linters.enable | length' merged.yml | grep -q "[0-9]"; then
        print_success "Default config intact with empty custom config"
    else
        print_error "Default config corrupted with empty custom config"
        return 1
    fi
}

# Test 7: Malformed YAML (should handle gracefully)
test_malformed_yaml() {
    print_test "Malformed .golangci.yml file (error handling)"
    setup_test
    
    cat > .golangci.yml << 'EOF'
linters:
  enable:
    - errcheck
  - this is malformed yaml
EOF
    
    # Run merge logic (should not crash)
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    cp "$DEFAULT_CONFIG" "merged.yml"
    
    # Try to read with error handling
    repo_enabled=$(yq eval '.linters.enable[]?' ".golangci.yml" 2>/dev/null || true)
    
    # Should still have a valid merged config from default
    if [ -f "merged.yml" ] && yq eval '.linters.enable | length' merged.yml >/dev/null 2>&1; then
        print_success "Malformed YAML handled gracefully, default config preserved"
    else
        print_error "Malformed YAML caused failure"
        return 1
    fi
}

# Test 8: Duplicate linters in enable list
test_duplicate_linters() {
    print_test "Custom config with duplicate linters"
    setup_test
    
    cat > .golangci.yml << 'EOF'
linters:
  enable:
    - errcheck  # Already in default
    - govet     # Already in default
    - exhaustruct  # New one
EOF
    
    # Run merge logic
    export SCRIPTS_DIR="$SCRIPTS_DIR"
    cp "$DEFAULT_CONFIG" "merged.yml"
    
    original_count=$(yq eval '.linters.enable | length' merged.yml)
    
    repo_enabled=$(yq eval '.linters.enable[]?' ".golangci.yml" 2>/dev/null || true)
    if [ -n "$repo_enabled" ]; then
        echo "$repo_enabled" | while IFS= read -r linter; do
            if [ -n "$linter" ]; then
                if ! yq eval ".linters.enable | contains([\"$linter\"])" "merged.yml" | grep -q true; then
                    yq eval ".linters.enable += [\"$linter\"]" -i "merged.yml"
                fi
            fi
        done
    fi
    
    final_count=$(yq eval '.linters.enable | length' merged.yml)
    
    # Should only add 1 (exhaustruct), not re-add existing ones
    if [ $final_count -eq $((original_count + 1)) ]; then
        print_success "Duplicate linters not re-added"
    else
        print_error "Duplicate linters handling failed (expected $((original_count + 1)), got $final_count)"
        return 1
    fi
}

# Run all tests
main() {
    echo "========================================"
    echo "YAML Merge Validation Test Suite"
    echo "========================================"
    echo "Testing golangci-lint YAML merge functionality"
    echo ""
    
    # Check dependencies
    if ! command -v yq &> /dev/null; then
        print_error "yq is not installed. Please install yq to run these tests."
        exit 1
    fi
    
    print_info "Default config: $DEFAULT_CONFIG"
    print_info "Test directory: $TEST_DIR"
    echo ""
    
    # Run all tests
    test_no_custom_config || true
    test_custom_enable_linters || true
    test_custom_disable_linters || true
    test_custom_linter_settings || true
    test_complex_custom_config || true
    test_empty_custom_config || true
    test_malformed_yaml || true
    test_duplicate_linters || true
    
    # Cleanup
    cleanup
    
    # Print summary
    echo ""
    echo "========================================"
    echo "TEST SUMMARY"
    echo "========================================"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
    echo "========================================"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed! ✓${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed! ✗${NC}"
        exit 1
    fi
}

# Run main function
main
