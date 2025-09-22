#!/usr/bin/env sh
# Test project for validating Go 1.25.1 test script
# This script creates a minimal Go project to test the golang/test/run.sh script

TEST_DIR="/tmp/go-test-validation"
echo "Creating test project in $TEST_DIR..."

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/cmd/app" "$TEST_DIR/internal/service"

# Create go.mod with Go 1.25.1
cat > "$TEST_DIR/go.mod" << 'EOF'
module github.com/test/validation

go 1.25.1
EOF

# Create main application
cat > "$TEST_DIR/cmd/app/main.go" << 'EOF'
package main

import "fmt"

func main() {
	fmt.Println("Test application")
}

func Calculate(a, b int) int {
	return a + b
}
EOF

# Create test for main application
cat > "$TEST_DIR/cmd/app/main_test.go" << 'EOF'
package main

import "testing"

func TestCalculate(t *testing.T) {
	result := Calculate(5, 3)
	if result != 8 {
		t.Errorf("Calculate(5, 3) = %d; want 8", result)
	}
}
EOF

# Create internal service
cat > "$TEST_DIR/internal/service/processor.go" << 'EOF'
package service

func Process(data string) string {
	return "processed: " + data
}
EOF

# Create test for internal service
cat > "$TEST_DIR/internal/service/processor_test.go" << 'EOF'
package service

import "testing"

func TestProcess(t *testing.T) {
	result := Process("test")
	if result != "processed: test" {
		t.Errorf("Process(test) = %s; want processed: test", result)
	}
}
EOF

echo "Test project created successfully at $TEST_DIR"
echo "Structure:"
find "$TEST_DIR" -type f | sort

echo ""
echo "Running the Go test script..."
cd "$TEST_DIR"

# Run the test script directly with absolute path
"/home/runner/work/pipelines/pipelines/global/scripts/golang/test/run.sh"

echo ""
echo "Test validation completed. Check output above for any errors."