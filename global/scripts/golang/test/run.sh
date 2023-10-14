#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

export GOPATH="$(pwd)/.go" # the GOPATH must be absolute
export PATH="$PATH:$GOPATH/bin" # this is a workaround to detect the new GOPATH

export INIT_SCRIPT="config.sh"
[[ -f $INIT_SCRIPT ]] && ./$INIT_SCRIPT || echo "The '$INIT_SCRIPT' file is not found, skipping..."

touch coverage.xml
go test -v -tags test,unit,integration -coverpkg ./main/... -covermode=count ./main/... -coverprofile=coverage.txt

go tool cover -func coverage.txt
go install github.com/boumenot/gocover-cobertura@latest
gocover-cobertura < coverage.txt > coverage.xml
