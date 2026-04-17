#!/usr/bin/env sh
set -e

# Generates a CycloneDX Software Bill of Materials for a Terraform project.
# Trivy scans `.terraform.lock.hcl` files (provider pins) and Terraform
# `source =` references (module pins, including private Git/SSH remotes
# when an SSH key is configured upstream) and emits a CycloneDX 1.6 JSON
# document. The BOM is written to `build/reports/bom.json` so the existing
# `global/scripts/tools/dependency-track/run.sh` upload script picks it up
# without any additional wiring.
#
# Consumers can override the BOM project identity via two env vars:
#   - DT_PROJECT_NAME     (default: git remote basename, e.g. `shared-toolbox`)
#   - DT_PROJECT_VERSION  (default: latest git tag, or `latest`)

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# Match the other CycloneDX scripts — write bom.json at the top of the
# reports directory (no tool-specific subdir) so the Dependency-Track
# uploader finds it at `$REPORT_PATH/bom.json`.
BOM_PATH="$PREFIX$REPORT_PATH" && mkdir -p "$BOM_PATH"
bomFile="$BOM_PATH/bom.json"

# Install Trivy if not already available on the agent (same pattern as
# `global/scripts/tools/trivy/run.sh`).
if ! command -v trivy > /dev/null 2>&1; then
  echo "Downloading Trivy..."
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /tmp
  export PATH="/tmp:$PATH"
fi

# `basename -s` is a GNU extension and breaks on BusyBox/Alpine, so strip
# the `.git` suffix with POSIX parameter expansion instead.
originUrl="$(git remote get-url origin 2>/dev/null || echo unknown)"
originRepo="$(basename "$originUrl")"
originRepo="${originRepo%.git}"
PROJECT_NAME="${DT_PROJECT_NAME:-$originRepo}"
PROJECT_VERSION="${DT_PROJECT_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo latest)}"

echo "Generating CycloneDX BOM for Terraform project '$PROJECT_NAME' ($PROJECT_VERSION)..."
trivy filesystem \
  --format cyclonedx \
  --output "$bomFile" \
  "$(pwd)"

# Trivy's CycloneDX writer defaults `metadata.component.name` to the scan
# target basename (the CI agent working directory, e.g. `s`). Override it
# so Dependency-Track associates the BOM with the right project.
tmpFile="$BOM_PATH/bom.tmp.json"
jq --arg name "$PROJECT_NAME" \
   --arg version "$PROJECT_VERSION" \
   '.metadata.component.name = $name | .metadata.component.version = $version' \
   "$bomFile" > "$tmpFile"
mv "$tmpFile" "$bomFile"

echo "CycloneDX BOM written to $bomFile (name=$PROJECT_NAME version=$PROJECT_VERSION)."
