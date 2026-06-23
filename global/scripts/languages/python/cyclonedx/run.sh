#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# TODO: this should not be needed since it's covered by the parent YAML file that calls this shell script
BOM_PATH="$PREFIX$REPORT_PATH" && mkdir -p "$BOM_PATH"
# Build the SBOM and let cyclonedx-py populate the root `metadata.component`
# (name, type, bom-ref) from the project's pyproject.toml (PEP 621) rather than
# hand-patching it afterwards. CycloneDX requires `component.type`; without a
# valid root component, Dependency-Track (>= 4.11, BOM validation on by default)
# rejects the upload with HTTP 400.
pdm run cyclonedx-py environment "$(pdm info --python)" \
  --pyproject pyproject.toml --mc-type application \
  --of JSON -o "$BOM_PATH/bom.json"
# `version` is the one field PEP 621 may leave dynamic (resolved by the build
# backend, e.g. pdm-backend), so resolve it via pdm and inject only that.
version=$(pdm show --version 2>/dev/null)
jq --arg version "$version" \
   '.metadata.component.version = $version' \
   "$BOM_PATH/bom.json" > "$BOM_PATH/temp.json"
mv "$BOM_PATH/temp.json" "$BOM_PATH/bom.json"
