#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

# TODO: this should not be needed since it's covered by the parent YAML file that calls this shell script
BOM_PATH="$PREFIX$REPORT_PATH" && mkdir -p "$BOM_PATH"
pdm run cyclonedx-py environment "$(pdm info --python)" --of JSON -o "$BOM_PATH/bom.json"
name=$(pdm show --name 2>/dev/null)
version=$(pdm show --version 2>/dev/null)
jq --arg name "$name" \
   --arg version "$version" \
   '.metadata.component.name = $name | .metadata.component.version = $version' \
   "$BOM_PATH/bom.json" > "$BOM_PATH/temp.json"
mv "$BOM_PATH/temp.json" "$BOM_PATH/bom.json"
