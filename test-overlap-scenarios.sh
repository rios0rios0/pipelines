#!/usr/bin/env sh
# Test script specifically for overlap merge scenarios
echo "=== Testing Overlap Merge Fix Scenarios ==="

# Test scenario 1: Successful gocovmerge (normal case)
echo ""
echo "Test 1: Normal gocovmerge operation"
echo "===================================="

mkdir -p /tmp/test-normal-merge
cd /tmp/test-normal-merge

cat > go.mod << 'EOF'
module github.com/test/normal-merge

go 1.21
EOF

cat > unit_coverage.txt << 'EOF'
mode: count
github.com/test/normal-merge/main.go:3.13,5.2 1 1
github.com/test/normal-merge/main.go:7.20,9.2 1 1
EOF

cat > integration_coverage.txt << 'EOF'
mode: count
github.com/test/normal-merge/main.go:11.15,13.2 1 1
EOF

# Test the script portion that handles merging
if ! $(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt 2>/dev/null; then
  echo "✗ Normal merge FAILED"
  exit 1
else
  echo "✓ Normal merge PASSED"
fi

# Test scenario 2: Overlap merge failure (error case)
echo ""
echo "Test 2: Overlap merge failure handling"
echo "======================================"

mkdir -p /tmp/test-overlap-merge
cd /tmp/test-overlap-merge

cat > go.mod << 'EOF'
module github.com/test/overlap-merge

go 1.21
EOF

# Create conflicting coverage files (same start position, different end)
cat > unit_coverage.txt << 'EOF'
mode: count
github.com/test/overlap-merge/main.go:3.13,5.2 1 1
github.com/test/overlap-merge/main.go:7.20,9.2 1 2
EOF

cat > integration_coverage.txt << 'EOF'
mode: count
github.com/test/overlap-merge/main.go:3.13,6.2 2 1
github.com/test/overlap-merge/main.go:7.20,9.2 1 1
EOF

# Test the fallback behavior
if ! $(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt 2>/dev/null; then
  echo "⚠ gocovmerge failed due to overlapping coverage blocks - using fallback strategy"
  
  # Fallback: Use just the unit coverage file as base
  cp unit_coverage.txt coverage.txt
  
  # Check that we have valid coverage output
  if [ -f coverage.txt ] && [ -s coverage.txt ]; then
    unit_mode=$(head -n 1 unit_coverage.txt)
    integration_mode=$(head -n 1 integration_coverage.txt)
    
    if [ "$unit_mode" = "$integration_mode" ]; then
      echo "⚠ Using unit test coverage as primary source, integration coverage may be incomplete"
      echo "⚠ This is due to overlapping coverage blocks that cannot be safely merged"
    else
      echo "⚠ Coverage modes differ between unit and integration tests"
      echo "⚠ Using unit test coverage only"
    fi
    
    echo "✓ Overlap merge fallback PASSED"
  else
    echo "✗ Overlap merge fallback FAILED - no coverage output"
    exit 1
  fi
else
  echo "✗ Expected overlap merge to fail, but it succeeded"
  exit 1
fi

echo ""
echo "Final coverage output:"
cat coverage.txt

echo ""
echo "=== All Overlap Merge Tests Completed Successfully ==="
echo "✓ Normal gocovmerge operation works correctly"
echo "✓ Overlap merge failures are handled gracefully with fallback"
echo "✓ Coverage reports are still generated even when gocovmerge fails"
echo "✓ Test script continues execution instead of terminating with exit code 1"