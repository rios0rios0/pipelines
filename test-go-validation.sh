#!/usr/bin/env sh
# Comprehensive test script for validating Go 1.25.1 test script
# This script creates multiple test scenarios to ensure the script works correctly

echo "=== Testing Go Test Script with Multiple Scenarios ==="

# Test 1: Project with build tags
echo ""
echo "Test 1: Project with build tags"
echo "================================"

TEST_DIR_TAGS="/tmp/go-test-validation-tags"
rm -rf "$TEST_DIR_TAGS"
mkdir -p "$TEST_DIR_TAGS/cmd/app" "$TEST_DIR_TAGS/internal/service" "$TEST_DIR_TAGS/internal/helpers"

cat > "$TEST_DIR_TAGS/go.mod" << 'EOF'
module github.com/test/validation-tags

go 1.25.1
EOF

cat > "$TEST_DIR_TAGS/cmd/app/main.go" << 'EOF'
package main

import "fmt"

func main() {
	fmt.Println("Test application")
}

func Calculate(a, b int) int {
	return a + b
}
EOF

cat > "$TEST_DIR_TAGS/cmd/app/main_test.go" << 'EOF'
//go:build unit

package main

import "testing"

func TestCalculate(t *testing.T) {
	result := Calculate(5, 3)
	if result != 8 {
		t.Errorf("Calculate(5, 3) = %d; want 8", result)
	}
}
EOF

cat > "$TEST_DIR_TAGS/internal/service/processor.go" << 'EOF'
package service

func Process(data string) string {
	return "processed: " + data
}
EOF

cat > "$TEST_DIR_TAGS/internal/service/processor_test.go" << 'EOF'
//go:build unit

package service

import "testing"

func TestProcess(t *testing.T) {
	result := Process("test")
	if result != "processed: test" {
		t.Errorf("Process(test) = %s; want processed: test", result)
	}
}
EOF

cat > "$TEST_DIR_TAGS/internal/helpers/helper.go" << 'EOF'
package helpers

func Helper() bool {
	return true
}
EOF

cat > "$TEST_DIR_TAGS/internal/helpers/helper_test.go" << 'EOF'
//go:build integration

package helpers

import "testing"

func TestHelper(t *testing.T) {
	result := Helper()
	if !result {
		t.Errorf("Helper() = %v; want true", result)
	}
}
EOF

cd "$TEST_DIR_TAGS"
echo "Running test with build tags..."
if /home/runner/work/pipelines/pipelines/global/scripts/golang/test/run.sh; then
  echo "✓ Test 1 PASSED: Build tags scenario"
else
  echo "✗ Test 1 FAILED: Build tags scenario"
  exit 1
fi

# Test 2: Project without build tags (backward compatibility)
echo ""
echo "Test 2: Project without build tags (backward compatibility)"
echo "=========================================================="

TEST_DIR_NO_TAGS="/tmp/go-test-validation-no-tags"
rm -rf "$TEST_DIR_NO_TAGS"
mkdir -p "$TEST_DIR_NO_TAGS/cmd/app" "$TEST_DIR_NO_TAGS/internal/service"

cat > "$TEST_DIR_NO_TAGS/go.mod" << 'EOF'
module github.com/test/validation-no-tags

go 1.25.1
EOF

cat > "$TEST_DIR_NO_TAGS/cmd/app/main.go" << 'EOF'
package main

import "fmt"

func main() {
	fmt.Println("Test application")
}

func Calculate(a, b int) int {
	return a + b
}
EOF

cat > "$TEST_DIR_NO_TAGS/cmd/app/main_test.go" << 'EOF'
package main

import "testing"

func TestCalculate(t *testing.T) {
	result := Calculate(5, 3)
	if result != 8 {
		t.Errorf("Calculate(5, 3) = %d; want 8", result)
	}
}
EOF

cat > "$TEST_DIR_NO_TAGS/internal/service/processor.go" << 'EOF'
package service

func Process(data string) string {
	return "processed: " + data
}
EOF

cat > "$TEST_DIR_NO_TAGS/internal/service/processor_test.go" << 'EOF'
package service

import "testing"

func TestProcess(t *testing.T) {
	result := Process("test")
	if result != "processed: test" {
		t.Errorf("Process(test) = %s; want processed: test", result)
	}
}
EOF

cd "$TEST_DIR_NO_TAGS"
echo "Running test without build tags..."
if /home/runner/work/pipelines/pipelines/global/scripts/golang/test/run.sh; then
  echo "✓ Test 2 PASSED: No build tags scenario (backward compatibility)"
else
  echo "✗ Test 2 FAILED: No build tags scenario"
  exit 1
fi

# Test 3: Project with no test files
echo ""
echo "Test 3: Project with no test files"
echo "=================================="

TEST_DIR_NO_TESTS="/tmp/go-test-validation-no-tests"
rm -rf "$TEST_DIR_NO_TESTS"
mkdir -p "$TEST_DIR_NO_TESTS/cmd/app" "$TEST_DIR_NO_TESTS/internal/service"

cat > "$TEST_DIR_NO_TESTS/go.mod" << 'EOF'
module github.com/test/validation-no-tests

go 1.25.1
EOF

cat > "$TEST_DIR_NO_TESTS/cmd/app/main.go" << 'EOF'
package main

import "fmt"

func main() {
	fmt.Println("Test application")
}

func Calculate(a, b int) int {
	return a + b
}
EOF

cat > "$TEST_DIR_NO_TESTS/internal/service/processor.go" << 'EOF'
package service

func Process(data string) string {
	return "processed: " + data
}
EOF

cd "$TEST_DIR_NO_TESTS"
echo "Running test with no test files..."
if /home/runner/work/pipelines/pipelines/global/scripts/golang/test/run.sh; then
  echo "✓ Test 3 PASSED: No test files scenario"
else
  echo "✗ Test 3 FAILED: No test files scenario"
  exit 1
fi

echo ""
echo "=== All Tests Completed Successfully ==="
echo "The Go test script correctly handles:"
echo "- Projects with build tags (unit/integration separation)"
echo "- Projects without build tags (backward compatibility)"  
echo "- Projects with no test files"
echo "- Avoids Go 1.25.1 covdata tool dependency issues"
echo ""
echo "Test validation completed successfully!"