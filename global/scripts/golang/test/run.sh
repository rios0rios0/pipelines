#!/usr/bin/env sh
set -e

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

export GOPATH="$(pwd)/.go" # the GOPATH must be absolute
export PATH="$PATH:$GOPATH/bin" # this is a workaround to detect the new GOPATH

export INIT_SCRIPT="config.sh"
[ -f "$INIT_SCRIPT" ] && ./"$INIT_SCRIPT" || echo "The '$INIT_SCRIPT' file is not found, skipping..."

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

# Download and install docker for integration tests with test containers
distro=$(grep '^NAME=' /etc/os-release | awk -F= '{print $2}' | tr -d '"')
if ["$distro" != "Arch Linux" && [ "$distro" != "Gentoo" ]; then
  echo "Installing docker"
  curl -fsSL https://get.docker.com | bash
else
  echo "Skipping installation for unsupported distro"
fi

# Trim leading or trailing spaces
directories=$(echo $directories | sed 's/^ *//;s/ *$//')
echo "Testing code in the following directories: $directories"

go install github.com/wadey/gocovmerge@latest

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

test_exit_code=$?

gocovmerge unit_coverage.txt integration_coverage.txt > coverage.txt

rm unit_coverage.txt integration_coverage.txt

go tool cover -func coverage.txt
cover_exit_code=$?

go install github.com/boumenot/gocover-cobertura@latest
install_exit_code=$?

gocover-cobertura < coverage.txt > coverage.xml
cobertura_exit_code=$?

# Exit with the highest exit code
exit_code=$((test_exit_code > cover_exit_code ? test_exit_code : cover_exit_code))
exit_code=$((exit_code > install_exit_code ? exit_code : install_exit_code))
exit_code=$((exit_code > cobertura_exit_code ? exit_code : cobertura_exit_code))

# Exit
exit $exit_code
