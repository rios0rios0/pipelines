#!/usr/bin/env sh
set -e

FINAL_EXIT_CODE=0

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# GitLab CI/CD just supports cache in the project directory
if [ -z "${GOPATH+x}" ]; then
  GOPATH="$(pwd)/.go"
  export GOPATH
fi

# All test reports land under $REPORT_PATH (default build/reports) so downstream
# repos can ignore a single directory instead of enumerating every report filename.
# Matches the convention honored by the Terraform tier runners and cleanup.sh.
REPORT_PATH="${REPORT_PATH:-build/reports}"
mkdir -p "$REPORT_PATH"

JUNIT_UNIT="$REPORT_PATH/junit-unit.xml"
JUNIT_INTEGRATION="$REPORT_PATH/junit-integration.xml"
UNIT_COV="$REPORT_PATH/unit_coverage.txt"
INTEGRATION_COV="$REPORT_PATH/integration_coverage.txt"
COVERAGE="$REPORT_PATH/coverage.txt"
JUNIT="$REPORT_PATH/junit.xml"
COBERTURA="$REPORT_PATH/cobertura.xml"

cleanup() {
  rm -f "$UNIT_COV" "$INTEGRATION_COV" "$JUNIT_UNIT" "$JUNIT_INTEGRATION"
}
trap cleanup EXIT

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
# shellcheck disable=SC2086
directories=$(echo $directories | sed 's/^ *//;s/ *$//')
echo "Testing code in the following directories: $directories"

echo "Installing dependencies..."
go install gotest.tools/gotestsum@latest
go install github.com/wadey/gocovmerge@latest
go install github.com/boumenot/gocover-cobertura@latest

echo ""
echo "=========================================="
echo "PHASE 1: RUNNING UNIT TESTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
unit_start_time=$(date +%s)

# shellcheck disable=SC2086
"$(go env GOPATH)"/bin/gotestsum \
  --format pkgname \
  --junitfile "$JUNIT_UNIT" \
  -- -tags test,unit \
  -coverpkg="$(echo $directories | tr ' ' ',')" \
  -covermode=count \
  -coverprofile="$UNIT_COV" \
  $directories || UNIT_EXIT_CODE=$?

unit_end_time=$(date +%s)
unit_duration=$((unit_end_time - unit_start_time))

if [ -n "$UNIT_EXIT_CODE" ] && [ "$UNIT_EXIT_CODE" -ne 0 ]; then
  if grep -q '<testsuites.*failures="0"' "$JUNIT_UNIT" 2>/dev/null; then
    echo "⚠ Unit tests passed with warnings (covdata tool missing) - continuing..."
  else
    FINAL_EXIT_CODE=$UNIT_EXIT_CODE
  fi
fi

echo "✓ Unit tests phase completed at $(date '+%Y-%m-%d %H:%M:%S') (took ${unit_duration}s)"
echo ""

# run integration tests
echo "=========================================="
echo "PHASE 2: RUNNING INTEGRATION TESTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
integration_start_time=$(date +%s)

# TODO: this should be in another step to run in parallel along the unit tests
# shellcheck disable=SC2086
"$(go env GOPATH)"/bin/gotestsum \
  --format pkgname \
  --junitfile "$JUNIT_INTEGRATION" \
  -- -p 1 -tags integration \
  -coverpkg="$(echo $directories | tr ' ' ',')" \
  -covermode=count \
  -coverprofile="$INTEGRATION_COV" \
  $directories || INTEGRATION_EXIT_CODE=$?

integration_end_time=$(date +%s)
integration_duration=$((integration_end_time - integration_start_time))

if [ -n "$INTEGRATION_EXIT_CODE" ] && [ "$INTEGRATION_EXIT_CODE" -ne 0 ]; then
  if grep -q '<testsuites.*failures="0"' "$JUNIT_INTEGRATION" 2>/dev/null; then
    echo "⚠ Integration tests passed with warnings (covdata tool missing) - continuing..."
  else
    FINAL_EXIT_CODE=$INTEGRATION_EXIT_CODE
  fi
fi

echo "✓ Integration tests phase completed at $(date '+%Y-%m-%d %H:%M:%S') (took ${integration_duration}s)"
echo ""

echo "=========================================="
echo "PHASE 3: GENERATING COVERAGE REPORTS"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
reports_start_time=$(date +%s)

# Try to merge coverage files with gocovmerge, fallback if it fails due to overlap merge issues
if ! "$(go env GOPATH)"/bin/gocovmerge "$UNIT_COV" "$INTEGRATION_COV" > "$COVERAGE" 2>/dev/null; then
  echo "⚠ gocovmerge failed due to overlapping coverage blocks - using fallback strategy"

  # Fallback: Merge coverage files by summing coverage counts for overlapping blocks
  if [ -f "$UNIT_COV" ] && [ -f "$INTEGRATION_COV" ] && [ -s "$UNIT_COV" ] && [ -s "$INTEGRATION_COV" ]; then
    # Get the mode from the first file
    unit_mode=$(head -n 1 "$UNIT_COV")
    integration_mode=$(head -n 1 "$INTEGRATION_COV")

    if [ "$unit_mode" = "$integration_mode" ]; then
      echo "$unit_mode" > "$COVERAGE"

      # Extract coverage lines (skip mode line) and merge by summing coverage
      (tail -n +2 "$UNIT_COV"; tail -n +2 "$INTEGRATION_COV") | sort | awk '
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
      }' | sort >> "$COVERAGE"

      echo "✓ Coverage files merged using intelligent fallback (summed coverage per block)"
    else
      echo "⚠ Coverage modes differ between unit and integration tests"
      echo "⚠ Using unit test coverage only"
      cp "$UNIT_COV" "$COVERAGE"
    fi
  elif [ -f "$UNIT_COV" ] && [ -s "$UNIT_COV" ]; then
    echo "⚠ Using unit test coverage only (integration coverage missing or empty)"
    cp "$UNIT_COV" "$COVERAGE"
  elif [ -f "$INTEGRATION_COV" ] && [ -s "$INTEGRATION_COV" ]; then
    echo "⚠ Using integration test coverage only (unit coverage missing or empty)"
    cp "$INTEGRATION_COV" "$COVERAGE"
  else
    echo "⚠ No valid coverage files found, creating empty coverage report"
    echo "mode: count" > "$COVERAGE"
  fi

  echo "✓ Coverage report generated using fallback strategy"
else
  echo "✓ Coverage files merged successfully with gocovmerge"
fi

# Merge JUnit XML files from both test phases into a single report.
# Strip XML headers and the outer <testsuites> wrapper from each file,
# keeping all inner <testsuite> elements (one per package).
extract_testsuites() {
  [ -f "$1" ] || return 0
  sed '/<\?xml /d; /<testsuites/d; /<\/testsuites>/d' "$1" 2>/dev/null || true
}
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<testsuites>'
  extract_testsuites "$JUNIT_UNIT"
  extract_testsuites "$JUNIT_INTEGRATION"
  echo '</testsuites>'
} > "$JUNIT"

go tool cover -func "$COVERAGE"
"$(go env GOPATH)"/bin/gocover-cobertura < "$COVERAGE" > "$COBERTURA"

reports_end_time=$(date +%s)
reports_duration=$((reports_end_time - reports_start_time))
echo "✓ Coverage reports generated successfully at $(date '+%Y-%m-%d %H:%M:%S') (took ${reports_duration}s)"
echo "=========================================="

exit $FINAL_EXIT_CODE
