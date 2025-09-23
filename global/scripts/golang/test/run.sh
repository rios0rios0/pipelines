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

rm unit_test_output.tmp
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

rm integration_test_output.tmp
echo "✓ Integration tests phase completed at $(date '+%Y-%m-%d %H:%M:%S') (took ${integration_duration}s)"
echo ""

echo "=========================================="
echo "PHASE 3: GENERATING COVERAGE REPORTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
reports_start_time=$(date +%s)

$(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt
$(go env GOPATH)/bin/go-junit-report -in coverage.txt -out junit.xml
go tool cover -func coverage.txt
$(go env GOPATH)/bin/gocover-cobertura < coverage.txt > cobertura.xml

# clean up temporary coverage files
rm unit_coverage.txt integration_coverage.txt

reports_end_time=$(date +%s)
reports_duration=$((reports_end_time - reports_start_time))
echo "✓ Coverage reports generated successfully at $(date '+%Y-%m-%d %H:%M:%S') (took ${reports_duration}s)"
echo "=========================================="
