#!/usr/bin/env sh
set -e

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

export GOPATH="$(pwd)/.go" # the GOPATH must be absolute
export PATH="$PATH:$GOPATH/bin" # this is a workaround to detect the new GOPATH

touch coverage.xml

# Find the directories to test
directories=""
[ -d "$(pwd)/main" ] && directories="$directories ./main/..."
[ -d "$(pwd)/cmd" ] && directories="$directories ./cmd/..."
[ -d "$(pwd)/pkg" ] && directories="$directories ./pkg/..."
[ -d "$(pwd)/internal" ] && directories="$directories ./internal/..."

# Check if directories is empty, meaning no directories were found
if [ -z "$directories" ]; then
  echo >&2 "No directories found to test"
  exit 1
fi

# Trim leading or trailing spaces
directories=$(echo $directories | sed 's/^ *//;s/ *$//')
echo "Testing code in the following directories: $directories"

echo "Installing dependencies..."
go install github.com/wadey/gocovmerge@latest
go install github.com/boumenot/gocover-cobertura@latest

# Run the tests
go test -v -tags test,unit \
  -coverpkg="$(echo $directories | tr ' ' ',')" \
  -covermode=count \
  -coverprofile=unit_coverage.txt \
  $directories

go test -p 1 -v -tags integration \
  -coverpkg="$(echo $directories | tr ' ' ',')" \
  -covermode=count \
  -coverprofile=integration_coverage.txt \
  $directories

gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt

rm unit_coverage.txt integration_coverage.txt

go tool cover -func coverage.txt

gocover-cobertura < coverage.txt > coverage.xml
