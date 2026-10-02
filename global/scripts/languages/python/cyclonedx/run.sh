#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# TODO: this should not be needed since it's covered by the parent YAML file that calls this shell script
BOM_PATH="$PREFIX$REPORT_PATH" && mkdir -p "$BOM_PATH"

# CycloneDX requires the root `metadata.component.type`, and Dependency-Track
# (>= 4.11, BOM validation on by default) rejects uploads without it (HTTP 400).
# Not every PDM project is an application, so derive the type from the project
# itself: PDM marks installable libraries with `distribution = true` (PDM >= 2.12)
# or the older `package-type = "library"` (PDM 2.11) under `[tool.pdm]`.
# Consumers can force any valid CycloneDX type by exporting CYCLONEDX_MC_TYPE.
if [ -z "$CYCLONEDX_MC_TYPE" ]; then
  CYCLONEDX_MC_TYPE="application"
  if sed -n '/^\[tool\.pdm\]/,/^\[/p' pyproject.toml 2>/dev/null |
      grep -Eq '^[[:space:]]*(distribution[[:space:]]*=[[:space:]]*true|package-type[[:space:]]*=[[:space:]]*"library")'; then
    CYCLONEDX_MC_TYPE="library"
  fi
fi

# Build the SBOM and let cyclonedx-py populate the root `metadata.component`
# (name, type, bom-ref) from the project's pyproject.toml (PEP 621) rather than
# hand-patching it afterwards.
pdm run cyclonedx-py environment "$(pdm info --python)" \
  --pyproject pyproject.toml --mc-type "$CYCLONEDX_MC_TYPE" \
  --of JSON -o "$BOM_PATH/bom.json"
# CycloneDX already reads a static PEP 621 version from pyproject.toml. Keep
# that value: `pdm show` refuses non-distribution projects, even when they have
# a version. Only a dynamic version needs PDM's build-backend resolution.
version=$(jq -r '.metadata.component.version // empty' "$BOM_PATH/bom.json")
if [ -z "$version" ]; then
  if ! version=$(pdm show --version); then
    echo "ERROR: could not resolve the SBOM project version; declare project.version or configure the PDM version backend." >&2
    exit 1
  fi
fi
case "$version" in
  *[![:space:]]*) ;;
  *)
    echo "ERROR: the SBOM project version is empty; declare project.version or configure the PDM version backend." >&2
    exit 1
    ;;
esac
jq --arg version "$version" \
   '.metadata.component.version = $version' \
   "$BOM_PATH/bom.json" > "$BOM_PATH/temp.json"
mv "$BOM_PATH/temp.json" "$BOM_PATH/bom.json"
