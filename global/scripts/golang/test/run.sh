#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

# GitLab CI/CD just supports cache in the project directory
if [ -z "${GOPATH+x}" ]; then
  export GOPATH="$(pwd)/.go"
fi

touch coverage.xml

echo "Installing dependencies..."
go install github.com/wadey/gocovmerge@latest
go install github.com/boumenot/gocover-cobertura@latest
go install github.com/jstemmer/go-junit-report/v2@latest

# Find packages that actually have test files
unit_test_packages=""
integration_test_packages=""
all_packages=""

# Find all packages with Go files (for complete coverage reporting)
for go_file in $(find . -name "*.go" -not -name "*_test.go" -not -path "./.go/*"); do
  pkg_dir=$(dirname "$go_file" | sed 's|^\./||')
  if [ "$pkg_dir" != "." ]; then
    all_packages="$all_packages ./$pkg_dir"
  fi
done

# Remove duplicates and sort all packages
all_packages=$(echo $all_packages | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')

# Look for packages with unit tests (build tag: unit OR no specific build tags for backward compatibility)
for test_file in $(find . -path "./.go" -prune -o -name "*_test.go" -print); do
  pkg_dir=$(dirname "$test_file" | sed 's|^\./||')
  if [ "$pkg_dir" != "." ]; then
    # Check for unit build tag
    if grep -q "//go:build unit" "$test_file" 2>/dev/null; then
      unit_test_packages="$unit_test_packages ./$pkg_dir"
    # Check for integration build tag  
    elif grep -q "//go:build integration" "$test_file" 2>/dev/null; then
      integration_test_packages="$integration_test_packages ./$pkg_dir"
    # For backward compatibility, include test files without build tags as unit tests
    elif ! grep -q "//go:build" "$test_file" 2>/dev/null; then
      unit_test_packages="$unit_test_packages ./$pkg_dir"
    fi
  fi
done

# Remove duplicates and sort
unit_test_packages=$(echo $unit_test_packages | tr ' ' '\n' | sort -u | tr '\n' ' ')
integration_test_packages=$(echo $integration_test_packages | tr ' ' '\n' | sort -u | tr '\n' ' ')

# Trim whitespace
unit_test_packages=$(echo $unit_test_packages | sed 's/^ *//;s/ *$//')
integration_test_packages=$(echo $integration_test_packages | sed 's/^ *//;s/ *$//')

echo "All packages with Go files: $all_packages"
echo "Unit test packages: $unit_test_packages"
echo "Integration test packages: $integration_test_packages"

# Run unit tests
echo ""
echo "=========================================="
echo "PHASE 1: RUNNING UNIT TESTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
unit_start_time=$(date +%s)
if [ -n "$unit_test_packages" ]; then
  echo "Running unit tests with coverage for all packages..."
  if [ -n "$all_packages" ]; then
    go test -v -tags test,unit \
      -coverpkg="$(echo $all_packages | tr ' ' ',')" \
      -covermode=count \
      -coverprofile=unit_coverage.txt \
      $unit_test_packages
  else
    go test -v -tags test,unit \
      -covermode=count \
      -coverprofile=unit_coverage.txt \
      $unit_test_packages
  fi
else
  echo "No unit test packages found, creating empty coverage file"
  touch unit_coverage.txt
fi
unit_end_time=$(date +%s)
unit_duration=$((unit_end_time - unit_start_time))
echo "✓ Unit tests phase completed at $(date '+%Y-%m-%d %H:%M:%S') (took ${unit_duration}s)"
echo ""

# Run integration tests
echo "=========================================="
echo "PHASE 2: RUNNING INTEGRATION TESTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
integration_start_time=$(date +%s)
if [ -n "$integration_test_packages" ]; then
  echo "Running integration tests with coverage for all packages..."
  if [ -n "$all_packages" ]; then
    go test -p 1 -v -tags integration \
      -coverpkg="$(echo $all_packages | tr ' ' ',')" \
      -covermode=count \
      -coverprofile=integration_coverage.txt \
      $integration_test_packages
  else
    go test -p 1 -v -tags integration \
      -covermode=count \
      -coverprofile=integration_coverage.txt \
      $integration_test_packages
  fi
else
  echo "No integration test packages found, creating empty coverage file"
  touch integration_coverage.txt
fi
integration_end_time=$(date +%s)
integration_duration=$((integration_end_time - integration_start_time))
echo "✓ Integration tests phase completed at $(date '+%Y-%m-%d %H:%M:%S') (took ${integration_duration}s)"
echo ""

echo "=========================================="
echo "PHASE 3: GENERATING COVERAGE REPORTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
reports_start_time=$(date +%s)
# Merge coverage files
$(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt && \
  rm unit_coverage.txt integration_coverage.txt

# Generate reports
$(go env GOPATH)/bin/go-junit-report -in coverage.txt -out junit.xml
go tool cover -func coverage.txt
$(go env GOPATH)/bin/gocover-cobertura < coverage.txt > cobertura.xml

reports_end_time=$(date +%s)
reports_duration=$((reports_end_time - reports_start_time))
echo "✓ Coverage reports generated successfully at $(date '+%Y-%m-%d %H:%M:%S') (took ${reports_duration}s)"
echo "=========================================="
