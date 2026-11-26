#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
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
  # One line per `main` package of the module, as `go list` resolves them, relative to the module
  # root (`.` for the root itself). A module may legitimately hold SEVERAL -- a server plus a
  # scheduled worker, a CLI plus its daemon -- and `-main` accepts exactly one path, so handing it
  # a multi-line list made cyclonedx-gomod refuse the whole run with
  # `invalid options: - main: "..." does not exist`. No BOM was written, the SBOM upload that
  # consumes it had nothing to send, and the job failed on every single build.
  #
  # `go list` rather than `find -name main.go`: what makes a directory an entry point is its
  # `package main`, not the name of a file in it. An AWS SAM function keeps `func main` in
  # `main/bootstrap.go`, and searching for `main.go` stopped every such repository with "no
  # directory containing Go files" before a BOM was written (KI-07). `go list` also skips what the
  # build skips: a nested module's own `main.go`, `vendor/`, `testdata/`, a `.go/` GOPATH, and a
  # `//go:build ignore` generator.
  if ! main_dirs="$(go list -e -f '{{if eq .Name "main"}}{{.Dir}}{{end}}' ./...)"; then
    echo "Could not list the packages of the Go module in $(pwd) (see the error above)."
    exit 1
  fi
  folders="$(printf '%s\n' "$main_dirs" | while IFS= read -r dir; do
    case "$dir" in
      '') ;;
      "$PWD") echo '.' ;;
      "$PWD"/*) echo "./${dir#"$PWD"/}" ;;
      *) echo "$dir" ;;
    esac
  done)"
  if [ -z "$folders" ]; then
    echo "Could not find a main package in the Go module in $(pwd)."
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

# cyclonedx-gomod writes the license its detector matched into `license.id` VERBATIM, and the
# detector (go-license-detector, whose licenses are SPDX's license-list-data files) names a
# DEPRECATED SPDX license after its file: `deprecated_GPL-2.0+`, not `GPL-2.0+`. No SPDX list holds
# such an id. Dependency-Track validates a BOM against the CycloneDX schema, whose `license.id` is
# an enumeration of the SPDX list, before it accepts it -- so ONE such module made it refuse the
# whole upload with HTTP 400 ("The uploaded BOM is invalid", `license.id: does not have a value in
# the enumeration`) and the project kept no inventory at all. A consumer's service failed that
# way on 2026-11-26 over github.com/golang/freetype, and no newer cyclonedx-gomod or
# go-license-detector release writes the id differently.
#
# The helper checks every license id against the SPDX list Dependency-Track validates with and
# rewrites only the ones that list does not hold: `deprecated_<id>` becomes `<id>`, and any other
# id becomes the license's `name`, which every schema version accepts. No license is dropped and
# `-licenses` stays, because the detected licenses are what the inventory is for; a BOM with
# nothing to rewrite is left byte for byte. It is Go, built from this checkout -- the job already
# has the Go it just installed cyclonedx-gomod with; see `licenses/internal/cli`.
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/global/scripts/shared/go-helper.sh"
go_helper_run global/scripts/languages/golang/cyclonedx/licenses "$BOM_PATH/bom.json"
