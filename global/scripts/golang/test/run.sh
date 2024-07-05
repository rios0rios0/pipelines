#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

export GOPATH="$(pwd)/.go" # the GOPATH must be absolute
export PATH="$PATH:$GOPATH/bin" # this is a workaround to detect the new GOPATH

export INIT_SCRIPT="config.sh"
[[ -f $INIT_SCRIPT ]] && ./$INIT_SCRIPT || echo "The '$INIT_SCRIPT' file is not found, skipping..."

touch coverage.xml

# determine the directory to use
dir="cmd"
[ -d "$(pwd)/main" ] && dir="main"

# Run the tests
go test -v -tags test,unit,integration -coverpkg ./$dir/... -covermode=count ./$dir/... -coverprofile=coverage.txt
test_exit_code=$?

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
