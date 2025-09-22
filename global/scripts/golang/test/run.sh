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

echo "Unit test packages: $unit_test_packages"
echo "Integration test packages: $integration_test_packages"

# Run unit tests
if [ -n "$unit_test_packages" ]; then
  echo "Running unit tests..."
  go test -v -tags test,unit \
    -covermode=count \
    -coverprofile=unit_coverage.txt \
    $unit_test_packages
else
  echo "No unit test packages found, creating empty coverage file"
  touch unit_coverage.txt
fi

# Run integration tests
if [ -n "$integration_test_packages" ]; then
  echo "Running integration tests..."
  go test -p 1 -v -tags integration \
    -covermode=count \
    -coverprofile=integration_coverage.txt \
    $integration_test_packages
else
  echo "No integration test packages found, creating empty coverage file"
  touch integration_coverage.txt
fi

# Merge coverage files
$(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt && \
  rm unit_coverage.txt integration_coverage.txt

# Generate reports
$(go env GOPATH)/bin/go-junit-report -in coverage.txt -out junit.xml
echo
echo "=== Coverage Summary ==="
go tool cover -func coverage.txt | tail -1
echo "=========================="
$(go env GOPATH)/bin/gocover-cobertura < coverage.txt > cobertura.xml
