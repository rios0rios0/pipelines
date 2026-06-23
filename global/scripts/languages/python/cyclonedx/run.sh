#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# TODO: this should not be needed since it's covered by the parent YAML file that calls this shell script
BOM_PATH="$PREFIX$REPORT_PATH" && mkdir -p "$BOM_PATH"
pdm run cyclonedx-py environment "$(pdm info --python)" --of JSON -o "$BOM_PATH/bom.json"
name=$(pdm show --name 2>/dev/null)
version=$(pdm show --version 2>/dev/null)
# `cyclonedx-py environment` emits no root `metadata.component`, so this jq
# creates it from scratch. CycloneDX requires `component.type`, and
# Dependency-Track (>= 4.11, BOM validation enabled by default) rejects an
# upload whose component is missing it with HTTP 400. Set it to "application"
# alongside the name/version so the generated BOM is schema-valid.
jq --arg name "$name" \
   --arg version "$version" \
   '.metadata.component.type = "application" | .metadata.component.name = $name | .metadata.component.version = $version' \
   "$BOM_PATH/bom.json" > "$BOM_PATH/temp.json"
mv "$BOM_PATH/temp.json" "$BOM_PATH/bom.json"
