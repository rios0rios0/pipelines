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

# Azure DevOps' checkout task runs `git sparse-checkout disable` on every job it
# checks out (agent knob `UseSparseCheckoutInCheckoutTask`). Disabling sparse
# checkout leaves `extensions.worktreeConfig=true` behind in `.git/config` while
# `core.repositoryformatversion` stays `0`. Git itself reads that pairing
# happily, but go-git -- which cyclonedx-gomod uses to resolve the main module's
# version -- refuses it outright:
#
#   failed to determine version of main module:
#   git: core.repositoryformatversion does not support extension: worktreeconfig
#
# `app` treats that as fatal: it exits non-zero having written no BOM at all, so
# the Dependency-Track upload that consumes the BOM had nothing to send and the
# `report:dependency-track` job failed on every build of every single-entry-point
# Go repository. `mod` only warns, which is quieter but worse -- it publishes the
# module with an EMPTY version, so Dependency-Track silently tracks an
# unversioned project and findings cannot be attributed to a release.
#
# The extension is vestigial once sparse checkout is off, so dropping it restores
# go-git without changing a single path in the worktree. `git sparse-checkout
# list` is what proves that: it exits non-zero ("this worktree is not sparse")
# exactly when the extension has nothing left to describe, and zero when the
# worktree really is sparse -- in which case the extension is load-bearing
# (`.git/config.worktree` holds `core.sparseCheckout`) and is left alone.
#
# `|| true` is required rather than defensive: `--unset-all` exits 5 when the key
# is absent, which is the normal case on GitLab CI and for a local run, and
# `set -e` would then abort the SBOM on the very platforms that never had the bug.
if git rev-parse --git-dir >/dev/null 2>&1 && ! git sparse-checkout list >/dev/null 2>&1; then
  git config --unset-all extensions.worktreeConfig 2>/dev/null || true
fi

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
