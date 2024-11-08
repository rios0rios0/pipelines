#!/usr/bin/env sh
set -e

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

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

# run the tests
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

$(go env GOPATH)/bin/gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt

rm unit_coverage.txt integration_coverage.txt

go tool cover -func coverage.txt

$(go env GOPATH)/bin/gocover-cobertura < coverage.txt > coverage.xml
