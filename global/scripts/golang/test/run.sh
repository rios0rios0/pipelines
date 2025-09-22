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

# Check if covdata tool is available for cross-package coverage
COVDATA_AVAILABLE=false
set +e  # Temporarily disable exit on error for the covdata check
go tool covdata >/dev/null 2>&1
COVDATA_EXIT_CODE=$?
set -e  # Re-enable exit on error
if [ $COVDATA_EXIT_CODE -eq 2 ]; then
  COVDATA_AVAILABLE=true
  echo "covdata tool is available, using cross-package coverage"
else
  echo "covdata tool not available (exit code: $COVDATA_EXIT_CODE), using individual package coverage"
fi

# Check Go version for compatibility
GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
GO_MAJOR=$(echo $GO_VERSION | cut -d. -f1)
GO_MINOR=$(echo $GO_VERSION | cut -d. -f2)

echo "Detected Go version: $GO_VERSION"

# Determine coverage strategy based on Go version and covdata availability
USE_CROSS_PACKAGE_COVERAGE=true
if [ "$GO_MAJOR" -gt 1 ] || ([ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -ge 25 ]); then
  if [ "$COVDATA_AVAILABLE" = "false" ]; then
    echo "Go 1.25+ detected but covdata not available, using individual package coverage"
    USE_CROSS_PACKAGE_COVERAGE=false
  fi
fi

if [ "$USE_CROSS_PACKAGE_COVERAGE" = "true" ]; then
  echo "Using cross-package coverage collection..."
  # run the tests with cross-package coverage
  go test -v -tags test,unit \
    -coverpkg="$(echo $directories | tr ' ' ',')" \
    -covermode=count \
    -coverprofile=unit_coverage.txt \
    $directories

  # TODO: this should be in another step to run in parallel along the unit tests
  go test -p 1 -v -tags integration \
    -coverpkg="$(echo $directories | tr ' ' ',')" \
    -covermode=count \
    -coverprofile=integration_coverage.txt \
    $directories
else
  echo "Using individual package coverage collection..."
  # run the tests with individual package coverage (avoids covdata dependency)
  go test -v -tags test,unit \
    -covermode=count \
    -coverprofile=unit_coverage.txt \
    $directories

  # TODO: this should be in another step to run in parallel along the unit tests
  go test -p 1 -v -tags integration \
    -covermode=count \
    -coverprofile=integration_coverage.txt \
    $directories
fi

$(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt && \
  rm unit_coverage.txt integration_coverage.txt
$(go env GOPATH)/bin/go-junit-report -in coverage.txt -out junit.xml
go tool cover -func coverage.txt
$(go env GOPATH)/bin/gocover-cobertura < coverage.txt > cobertura.xml
