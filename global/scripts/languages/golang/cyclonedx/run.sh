#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# Resolves GOPATH (GitLab CI/CD just supports cache in the project directory) and
# keeps the resulting module cache out of $TMPDIR, where its read-only entries
# cannot be deleted again.
. "$SCRIPTS_DIR/global/scripts/shared/go-modcache.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
resolve_go_paths

# TODO: this should not be needed since it's covered by the parent YAML file that calls this shell script
BOM_PATH="$PREFIX$REPORT_PATH" && mkdir -p "$BOM_PATH"

# PINNED. This generates the SBOM that the 35-management stage uploads to
# Dependency-Track, so an unpinned generator meant the inventory's shape and
# completeness could change without any change to the dependencies it describes.
echo "Installing CycloneDX Go Module $CYCLONEDX_GOMOD_VERSION..."
go install "github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@$CYCLONEDX_GOMOD_VERSION"

if [ -d "pkg" ]; then
  echo "Found 'pkg' directory, using 'cyclonedx-gomod mod' command..."
  "$(go env GOPATH)/bin/cyclonedx-gomod" mod -json -output "$BOM_PATH/bom.json" -licenses
else
  # One line per directory holding a `main.go`. A module may legitimately hold SEVERAL -- a
  # server plus a scheduled worker, a CLI plus its daemon -- and `-main` accepts exactly one
  # path, so handing it the raw multi-line result made cyclonedx-gomod refuse the whole run with
  # `invalid options: - main: "..." does not exist`. No BOM was written, the SBOM upload that
  # consumes it had nothing to send, and the job failed on every single build.
  folders="$(find . -type f -name main.go -not -path '*/.go/*' -exec dirname {} \;)"
  if [ -z "$folders" ]; then
    echo "Could not find a directory containing Go files"
    exit 1
  fi

  main_count="$(printf '%s\n' "$folders" | grep -c '^')"

  if [ "$main_count" -gt 1 ]; then
    # `app` describes ONE binary's reachable dependencies; with several binaries in the module no
    # single one represents the repository, and picking one arbitrarily would silently drop the
    # dependencies only the others pull in. `mod` describes the module -- a superset of every
    # binary's dependencies -- which is the safe direction for vulnerability tracking: it can
    # over-report a component, never miss one.
    echo "Found $main_count main packages, using 'cyclonedx-gomod mod' command..."
    "$(go env GOPATH)/bin/cyclonedx-gomod" mod -json -output "$BOM_PATH/bom.json" -licenses
  else
    echo "Using 'cyclonedx-gomod app' command..."
    "$(go env GOPATH)/bin/cyclonedx-gomod" app -json -output "$BOM_PATH/bom.json" -packages -files -licenses -main "$folders"
  fi
fi
