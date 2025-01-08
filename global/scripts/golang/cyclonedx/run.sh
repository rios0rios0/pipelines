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

# TODO: this should not be needed since it's covered by the parent YAML file that calls this shell script
BOM_PATH="$PREFIX$REPORT_PATH" && mkdir -p "$BOM_PATH"

echo "Installing CycloneDX Go Module..."
go install github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@latest

if [ -d "pkg" ]; then
  echo "Found 'pkg' directory, using 'cyclonedx-gomod mod' command..."
  "$(go env GOPATH)/bin/cyclonedx-gomod" mod -json -output "$BOM_PATH/bom.json" -licenses
else
  folder="$(find $(pwd) -type f -name main.go -exec dirname {} \;)"
  if [ -z "$folder" ]; then
    echo "Could not find a directory containing Go files"
    exit 1
  fi
  echo "Using 'cyclonedx-gomod app' command..."
  "$(go env GOPATH)/bin/cyclonedx-gomod" app -json -output "$BOM_PATH/bom.json" -packages -files -licenses -main "$folder"
fi
