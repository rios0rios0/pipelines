#!/usr/bin/env sh
set -e

# Generates a CycloneDX Software Bill of Materials for a Dart or Flutter
# project, for the `35-management` stage's Dependency-Track upload.
#
# WHY TRIVY AND NOT A DART-NATIVE GENERATOR
# There isn't one. `package:sbom` -- the only SBOM generator published on
# pub.dev -- emits SPDX and states CycloneDX is a future release; Dependency-
# Track ingests CycloneDX. `cdxgen` does emit CycloneDX for pub, but it is an
# npm package, so using it would drag a whole Node.js toolchain into a Dart job
# for one file. Trivy is already a dependency of this repository's security
# stage, already parses `pubspec.lock`, and already emits CycloneDX -- which is
# exactly how the Terraform SBOM is produced here, so this script is
# deliberately its close sibling.
#
# Read the Dart caveat in `../sca/run.sh` alongside this: Trivy records SDK-
# provided dependencies at version `0.0.0`, so those components appear in the
# BOM without a resolvable version. That is a completeness limitation of the
# BOM, not of the vulnerability scanning -- OSV-Scanner covers that separately.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

# Journals the Trivy invocation under `<reports>/dart-cyclonedx/`. The BOM
# itself does NOT go there -- see below.
dart_prepare_reports "dart-cyclonedx"

# The BOM goes at the TOP of the reports directory, with no per-tool subdir:
# `global/scripts/tools/dependency-track/run.sh` looks for it at exactly
# `$PREFIX$REPORT_PATH/bom.json`, matching the Go, Python and Terraform
# generators.
BOM_PATH="${PREFIX:-}${REPORT_PATH:-build/reports}"
mkdir -p "$BOM_PATH"
bomFile="$BOM_PATH/bom.json"

mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" && export PATH ;;
esac

if [ ! -f "${DART_PUBSPEC:-pubspec.yaml}" ]; then
  echo "ERROR: no pubspec.yaml in $(pwd); this is not a Dart or Flutter package." >&2
  exit 1
fi

if [ ! -f "${DART_LOCKFILE:-pubspec.lock}" ]; then
  echo "WARNING: no pubspec.lock found. Trivy resolves pub components from the LOCKFILE," >&2
  echo "         so the BOM will list few or no dependencies. Run 'dart pub get' first," >&2
  echo "         or commit the lockfile." >&2
fi

# Same self-updating install as the sibling generators (see
# `../../terraform/cyclonedx/run.sh` for the full rationale). Fail-safe: any
# uncertainty in the version lookup returns "no update", so a lookup blip never
# forces a needless re-download.
trivy_update_available() {
  _tv_latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/aquasecurity/trivy/releases/latest 2>/dev/null | sed 's#.*/tag/v\{0,1\}##')
  _tv_current=$(trivy --version 2>/dev/null | awk '/^Version:/{print $2}')
  case "$_tv_latest" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  case "$_tv_current" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  [ "$_tv_latest" != "$_tv_current" ]
}

if dart_is_dry_run; then
  echo "DRY RUN: skipping the Trivy install and the BOM generation."
elif ! command -v trivy > /dev/null 2>&1 || trivy_update_available; then
  echo "Downloading Trivy..."
  curl -fsSL --show-error https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /tmp || true
  if [ ! -x /tmp/trivy ]; then
    : "${TRIVY_PINNED_VERSION:=v0.72.0}"
    echo "Trivy 'latest' install failed; falling back to pinned $TRIVY_PINNED_VERSION..." >&2
    curl -fsSL --show-error https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /tmp "$TRIVY_PINNED_VERSION" || true
  fi
  if [ ! -x /tmp/trivy ]; then
    echo "ERROR: Trivy install failed (latest and pinned ${TRIVY_PINNED_VERSION:-v0.72.0}). See install output above." >&2
    exit 1
  fi
  mv /tmp/trivy "$HOME/.local/bin/trivy"
fi

# The pubspec is the authoritative identity for a pub package, so prefer it over
# the git remote the other generators fall back to.
PROJECT_NAME="${DT_PROJECT_NAME:-$(dart_pubspec_field name)}"
if [ -z "$PROJECT_NAME" ]; then
  originUrl="$(git remote get-url origin 2>/dev/null || echo unknown)"
  originRepo="$(basename "$originUrl")"
  PROJECT_NAME="${originRepo%.git}"
fi
PROJECT_VERSION="${DT_PROJECT_VERSION:-$(dart_pubspec_field version)}"
if [ -z "$PROJECT_VERSION" ]; then
  PROJECT_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo latest)"
fi

echo "Generating CycloneDX BOM for Dart project '$PROJECT_NAME' ($PROJECT_VERSION)..."
dart_run trivy filesystem --format cyclonedx --output "$bomFile" "$(pwd)"

if dart_is_dry_run; then
  echo "DRY RUN: no BOM was written."
  exit 0
fi

# Trivy names the root component after the scan target's basename (the CI
# working directory, e.g. `s`), and always emits its newest supported CycloneDX
# spec while Dependency-Track ingests only up to 1.6 -- rejecting anything newer
# with HTTP 400 `Unrecognized specVersion`. Both are corrected here exactly as
# in the Terraform generator; see that file for the upstream references.
maxSpec="${DT_CYCLONEDX_MAX_SPEC_VERSION:-1.6}"
if ! printf '%s' "$maxSpec" | grep -qE '^[0-9]+\.[0-9]+$'; then
  echo "ERROR: DT_CYCLONEDX_MAX_SPEC_VERSION='$maxSpec' is not a MAJOR.MINOR CycloneDX spec version (e.g. '1.6')." >&2
  exit 1
fi

tmpFile="$BOM_PATH/bom.tmp.json"
jq --arg name "$PROJECT_NAME" \
   --arg version "$PROJECT_VERSION" \
   --arg maxSpec "$maxSpec" \
   '
     .metadata.component.name = $name
     | .metadata.component.version = $version
     | if ((.specVersion // "0") | split(".") | map(tonumber)) > ($maxSpec | split(".") | map(tonumber))
       then .specVersion = $maxSpec
            | (if has("$schema") then ."$schema" = "http://cyclonedx.org/schema/bom-\($maxSpec).schema.json" else . end)
       else . end
   ' \
   "$bomFile" > "$tmpFile"
mv "$tmpFile" "$bomFile"

echo "CycloneDX BOM written to $bomFile (name=$PROJECT_NAME version=$PROJECT_VERSION, spec $(jq -r '.specVersion' "$bomFile"))."
