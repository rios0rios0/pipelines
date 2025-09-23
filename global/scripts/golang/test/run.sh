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
    # Exclude common test directory names from coverage
    case "$pkg_dir" in
      test|tests|testing|testdata|*/test|*/tests|*/testing|*/testdata|test/*|tests/*|testing/*|testdata/*)
        # Skip test directories
        ;;
      *)
        all_packages="$all_packages ./$pkg_dir"
        ;;
    esac
  fi
done

# Remove duplicates and sort all packages
all_packages=$(echo $all_packages | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')

# Look for packages with unit tests (build tag: unit OR no specific build tags for backward compatibility)
for test_file in $(find . -path "./.go" -prune -o -name "*_test.go" -print); do
  pkg_dir=$(dirname "$test_file" | sed 's|^\./||')
  if [ "$pkg_dir" != "." ]; then
    # Exclude common test directory names from test execution
    case "$pkg_dir" in
      test|tests|testing|testdata|*/test|*/tests|*/testing|*/testdata|test/*|tests/*|testing/*|testdata/*)
        # Skip test directories
        ;;
      *)
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
        ;;
    esac
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

# Check if we have any coverage data and merge it
unit_size=$(wc -c < unit_coverage.txt 2>/dev/null || echo 0)
integration_size=$(wc -c < integration_coverage.txt 2>/dev/null || echo 0)

if [ "$unit_size" -eq 0 ] && [ "$integration_size" -eq 0 ]; then
  # No test coverage at all - start with empty coverage file
  echo "mode: set" > coverage.txt
  echo "No test coverage found."
else
  # Merge existing coverage files
  echo "Merging existing test coverage..."
  $(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt
fi

# Now add synthetic coverage for any packages that don't appear in the coverage file
if [ -n "$all_packages" ]; then
  echo "Adding synthetic coverage for untested packages..."
  
  # Get the module name from go.mod
  module_name=$(go list -m 2>/dev/null || echo "unknown")
  
  # Create a temporary file for synthetic coverage
  temp_synthetic_coverage="$(mktemp /tmp/synthetic_coverage_XXXXXX.txt)"
  echo "mode: set" > "$temp_synthetic_coverage"
  
  # For each package, check if it appears in the existing coverage file
  for pkg in $all_packages; do
    pkg_clean=$(echo "$pkg" | sed 's|^\./||')
    
    # Check if this package is already covered in the coverage file
    if ! grep -q "^$module_name/$pkg_clean/" coverage.txt 2>/dev/null; then
      echo "  Adding synthetic coverage for package: $pkg_clean"
      
      # Find all .go files in this package (not test files)
      for go_file in $(find "$pkg" -name "*.go" -not -name "*_test.go" 2>/dev/null || true); do
        if [ -f "$go_file" ]; then
          # Get just the filename from the path
          filename=$(basename "$go_file")
          
          # Parse the Go file to find function declarations and add synthetic entries
          awk -v file="$filename" -v module="$module_name" -v pkg="$pkg_clean" '
          /^func [A-Z]/ {
            # Find function declarations (exported functions starting with capital letter)
            match($0, /^func [A-Za-z_][A-Za-z0-9_]*/)
            if (RSTART > 0) {
              func_name = substr($0, RSTART+5)
              gsub(/[^A-Za-z0-9_].*/, "", func_name)
              if (func_name != "main" && func_name != "") {
                # Add a synthetic coverage entry for this function (0 coverage)
                print module "/" pkg "/" file ":" NR ".1," (NR+1) ".1 1 0"
              }
            }
          }
          /^func main\(/ {
            # Handle main function specially
            print module "/" pkg "/" file ":" NR ".1," (NR+1) ".1 1 0"
          }
          ' "$go_file" >> "$temp_synthetic_coverage" 2>/dev/null || true
        fi
      done
    fi
  done
  
  # If we have synthetic coverage to add, merge it with the existing coverage
  if [ "$(wc -l < "$temp_synthetic_coverage")" -gt 1 ]; then
    echo "Merging synthetic coverage with existing coverage..."
    # Merge the original coverage with synthetic coverage
    $(go env GOPATH)/bin/gocovmerge coverage.txt "$temp_synthetic_coverage" > coverage_merged.txt
    mv coverage_merged.txt coverage.txt
  fi
  
  # Clean up temporary file
  rm -f "$temp_synthetic_coverage"
fi

# If the coverage file is still empty or has only the mode line, ensure we have a minimal valid coverage file
if [ "$(wc -l < coverage.txt)" -le 1 ]; then
  echo "# No coverage data found" >> coverage.txt
fi

# Clean up temporary coverage files
rm -f unit_coverage.txt integration_coverage.txt

# Generate reports
$(go env GOPATH)/bin/go-junit-report -in coverage.txt -out junit.xml
go tool cover -func coverage.txt
$(go env GOPATH)/bin/gocover-cobertura < coverage.txt > cobertura.xml

reports_end_time=$(date +%s)
reports_duration=$((reports_end_time - reports_start_time))
echo "✓ Coverage reports generated successfully at $(date '+%Y-%m-%d %H:%M:%S') (took ${reports_duration}s)"
echo "=========================================="
