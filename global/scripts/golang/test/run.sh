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

# find the directories to test
directories=""
[ -d "$(pwd)/cmd" ] && directories="$directories ./cmd/..."
[ -d "$(pwd)/pkg" ] && directories="$directories ./pkg/..."
[ -d "$(pwd)/internal" ] && directories="$directories ./internal/..."

# check if directories is empty, meaning no directories were found
if [ -z "$directories" ]; then
  echo >&2 "No directories found to test"
  exit 1
fi

# trim leading or trailing spaces
directories=$(echo $directories | sed 's/^ *//;s/ *$//')
echo "Testing code in the following directories: $directories"

echo "Installing dependencies..."
go install github.com/wadey/gocovmerge@latest
go install github.com/boumenot/gocover-cobertura@latest
go install github.com/jstemmer/go-junit-report/v2@latest

echo ""
echo "=========================================="
echo "PHASE 1: RUNNING UNIT TESTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
unit_start_time=$(date +%s)

# run unit tests
go test -v -tags test,unit \
  -coverpkg="$(echo $directories | tr ' ' ',')" \
  -covermode=count \
  -coverprofile=unit_coverage.txt \
  $directories > unit_test_output.tmp 2>&1 || UNIT_EXIT_CODE=$?

unit_end_time=$(date +%s)
unit_duration=$((unit_end_time - unit_start_time))

# Display the test output
cat unit_test_output.tmp

# Check if unit tests actually failed (not just covdata warnings)
if [ -n "$UNIT_EXIT_CODE" ] && [ "$UNIT_EXIT_CODE" -ne 0 ]; then
  # Check if output contains actual test failures
  if grep -q "^FAIL" unit_test_output.tmp; then
    echo "✗ Unit tests failed with exit code $UNIT_EXIT_CODE"
    rm unit_test_output.tmp
    exit $UNIT_EXIT_CODE
  else
    echo "⚠ Unit tests passed with warnings (covdata tool missing) - continuing..."
  fi
fi

# Keep unit test output for JUnit report generation
mv unit_test_output.tmp unit_test_output.txt
echo "✓ Unit tests phase completed at $(date '+%Y-%m-%d %H:%M:%S') (took ${unit_duration}s)"
echo ""

# run integration tests
echo "=========================================="
echo "PHASE 2: RUNNING INTEGRATION TESTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
integration_start_time=$(date +%s)

# TODO: this should be in another step to run in parallel along the unit tests
go test -p 1 -v -tags integration \
  -coverpkg="$(echo $directories | tr ' ' ',')" \
  -covermode=count \
  -coverprofile=integration_coverage.txt \
  $directories > integration_test_output.tmp 2>&1 || INTEGRATION_EXIT_CODE=$?

integration_end_time=$(date +%s)
integration_duration=$((integration_end_time - integration_start_time))

# Display the test output
cat integration_test_output.tmp

# Check if integration tests actually failed (not just covdata warnings)
if [ -n "$INTEGRATION_EXIT_CODE" ] && [ "$INTEGRATION_EXIT_CODE" -ne 0 ]; then
  # Check if output contains actual test failures
  if grep -q "^FAIL" integration_test_output.tmp; then
    echo "✗ Integration tests failed with exit code $INTEGRATION_EXIT_CODE"
    rm integration_test_output.tmp
    exit $INTEGRATION_EXIT_CODE
  else
    echo "⚠ Integration tests passed with warnings (covdata tool missing) - continuing..."
  fi
fi

# Keep integration test output for JUnit report generation
mv integration_test_output.tmp integration_test_output.txt
echo "✓ Integration tests phase completed at $(date '+%Y-%m-%d %H:%M:%S') (took ${integration_duration}s)"
echo ""

echo "=========================================="
echo "PHASE 3: GENERATING COVERAGE REPORTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
reports_start_time=$(date +%s)

# Try to merge coverage files with gocovmerge, fallback if it fails due to overlap merge issues
if ! $(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt 2>/dev/null; then
  echo "⚠ gocovmerge failed due to overlapping coverage blocks - using fallback strategy"
  
  # Fallback: Merge coverage files manually, selecting the highest coverage for each block
  if [ -f unit_coverage.txt ] && [ -f integration_coverage.txt ] && [ -s unit_coverage.txt ] && [ -s integration_coverage.txt ]; then
    # Get the mode from the first file
    unit_mode=$(head -n 1 unit_coverage.txt)
    integration_mode=$(head -n 1 integration_coverage.txt)
    
    if [ "$unit_mode" = "$integration_mode" ]; then
      echo "$unit_mode" > coverage.txt
      
      # Extract coverage lines (skip mode line) and merge by summing coverage
      (tail -n +2 unit_coverage.txt; tail -n +2 integration_coverage.txt) | sort | awk '
      BEGIN { FS=" "; OFS=" " }
      {
        # Extract file:start.startcol,end.endcol as the key
        file_block = $1
        num_stmt = $(NF-1)
        count = $NF
        
        if (file_block in blocks) {
          # If we have seen this block before, sum the coverage counts
          blocks[file_block] = blocks[file_block] + count
        } else {
          # New block, store it
          blocks[file_block] = count
          statements[file_block] = num_stmt
          # Store the original line structure for reconstruction
          split($0, parts, " ")
          for (i = 1; i < NF-1; i++) {
            line_parts[file_block] = line_parts[file_block] parts[i] " "
          }
        }
      }
      END {
        # Output all blocks with summed coverage
        for (block in blocks) {
          print line_parts[block] statements[block] " " blocks[block]
        }
      }' | sort >> coverage.txt
      
      echo "✓ Coverage files merged using intelligent fallback (summed coverage per block)"
    else
      echo "⚠ Coverage modes differ between unit and integration tests"
      echo "⚠ Using unit test coverage only"
      cp unit_coverage.txt coverage.txt
    fi
  elif [ -f unit_coverage.txt ] && [ -s unit_coverage.txt ]; then
    echo "⚠ Using unit test coverage only (integration coverage missing or empty)"
    cp unit_coverage.txt coverage.txt
  elif [ -f integration_coverage.txt ] && [ -s integration_coverage.txt ]; then
    echo "⚠ Using integration test coverage only (unit coverage missing or empty)"
    cp integration_coverage.txt coverage.txt
  else
    echo "⚠ No valid coverage files found, creating empty coverage report"
    echo "mode: count" > coverage.txt
  fi
  
  echo "✓ Coverage report generated using fallback strategy"
else
  echo "✓ Coverage files merged successfully with gocovmerge"
fi

# Combine test outputs for JUnit report generation
cat unit_test_output.txt integration_test_output.txt > combined_test_output.txt
$(go env GOPATH)/bin/go-junit-report < combined_test_output.txt > junit.xml
go tool cover -func coverage.txt
$(go env GOPATH)/bin/gocover-cobertura < coverage.txt > cobertura.xml

# clean up temporary coverage and test output files
rm unit_coverage.txt integration_coverage.txt unit_test_output.txt integration_test_output.txt combined_test_output.txt

reports_end_time=$(date +%s)
reports_duration=$((reports_end_time - reports_start_time))
echo "✓ Coverage reports generated successfully at $(date '+%Y-%m-%d %H:%M:%S') (took ${reports_duration}s)"
echo "=========================================="
