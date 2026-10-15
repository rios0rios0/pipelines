#!/usr/bin/env sh

# Parse command line arguments
FIX_FLAG=""
for arg in "$@"; do
  case $arg in
    fix|--fix)
      FIX_FLAG="--fix"
      shift
      ;;
    *)
      # Unknown option, ignore for now to maintain compatibility
      ;;
  esac
done

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# A merge step that fails must stop the run. Reporting the repository's own configuration as
# violations is worse than reporting nothing: it sends people to change correct code.
die() {
  echo "::error::golangci-lint config merge failed: $1"
  exit 1
}

# The shared helpers are sourced here rather than just before the golangci-lint install below,
# because the config merge runs FIRST and `resolve_yq` needs `download_verified`.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

# Resolving which of the two programs named `yq` is on this machine is a problem shared with
# the test suite that covers this script, so it lives in one place instead of two. See the
# comment at the top of that file for what accepting the wrong one silently did to a run.
. "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"

YQ=""

mergedYamlFile="merged.yml"
defaultYamlFile="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml"

if [ -f ".golangci.yml" ]; then
  # Start with the default config
  cp "$defaultYamlFile" "$mergedYamlFile"

  # Called only from the branch that has a config to merge. A repository without
  # `.golangci.yml` copies the shared default verbatim and never reads `$YQ`, so resolving it
  # there would add a network dependency -- and a way for the run to fail -- to the one case
  # that needs neither.
  resolve_yq || die "could not obtain mikefarah/yq ${YQ_VERSION}"

  # Collect enabled linters from repo config and add new ones in a single operation
  repo_enabled=$("$YQ" eval '.linters.enable[]?' ".golangci.yml") \
    || die 'could not read .linters.enable from .golangci.yml'
  if [ -n "$repo_enabled" ]; then
    to_enable=""
    for linter in $repo_enabled; do
      if [ -n "$linter" ]; then
        if ! "$YQ" eval ".linters.enable | contains([\"$linter\"])" "$mergedYamlFile" | grep -q true; then
          if [ -n "$to_enable" ]; then
            to_enable="$to_enable, \"$linter\""
          else
            to_enable="\"$linter\""
          fi
        fi
      fi
    done
    if [ -n "$to_enable" ]; then
      "$YQ" eval ".linters.enable += [${to_enable}]" -i "$mergedYamlFile" \
        || die 'could not add the enabled linters'
    fi
  fi

  # Collect disabled linters and remove them all in a single operation
  repo_disabled=$("$YQ" eval '.linters.disable[]?' ".golangci.yml") \
    || die 'could not read .linters.disable from .golangci.yml'
  if [ -n "$repo_disabled" ]; then
    filter=".linters.enable = (.linters.enable | map(select("
    first=true
    for linter in $repo_disabled; do
      if [ -n "$linter" ]; then
        if [ "$first" = true ]; then
          filter="${filter}. != \"$linter\""
          first=false
        else
          filter="${filter} and . != \"$linter\""
        fi
      fi
    done
    filter="${filter})))"
    "$YQ" eval "$filter" -i "$mergedYamlFile" || die 'could not remove the disabled linters'
  fi

  # Merge linter settings using yq.
  # Reads from the v1 legacy key "linters-settings" (used by project configs)
  # and merges into the v2 key "linters.settings" (required by golangci-lint v2).
  # Uses a two-step approach: extract settings to a temp file, then merge with *= to
  # avoid clobbering other keys under "linters" (e.g., "enable").
  repo_settings=$("$YQ" eval '."linters-settings" // ""' ".golangci.yml") \
    || die 'could not read linters-settings from .golangci.yml'
  if [ -n "$repo_settings" ] && [ "$repo_settings" != "" ] && [ "$repo_settings" != "null" ]; then
    "$YQ" eval '."linters-settings"' ".golangci.yml" > "$mergedYamlFile.settings.tmp" \
      || die 'could not extract linters-settings from .golangci.yml'
    "$YQ" eval '.linters.settings *= load("'"$mergedYamlFile"'.settings.tmp")' -i "$mergedYamlFile" \
      || die 'could not merge linters-settings into linters.settings'
    rm -f "$mergedYamlFile.settings.tmp"
  fi
else
  cp "$defaultYamlFile" "$mergedYamlFile"
fi

# Testing hook: `.github/tests/test-yaml-merge.sh` needs the merged configuration without paying
# for a lint run. It used to get that by keeping its own copy of the merge, and the two drifted --
# the copy wrote the v1 `linters-settings` key while this script writes the v2 `linters.settings`,
# so the suite asserted against a shape production never produced and stayed green through the
# bug above. Exposing the real merge is what makes that class of drift impossible.
if [ -n "$GOLANGCI_LINT_MERGE_ONLY" ]; then
  exit 0
fi

# Private scratch space for this run: the downloaded archive, its extraction and the lint log.
# The install used to work in fixed, shared paths -- `/tmp/golangci-lint.tar.gz`, extracted into
# `/tmp/golangci-lint-<version>-linux-<arch>` and then removed with `rm -rf` -- so two runs on one
# host (several runners per machine, or parallel `make lint` in different worktrees) overwrote and
# deleted each other's files mid-install. `mktemp -d` gives every run its own directory, and it
# honours TMPDIR.
GOLANGCI_TMP="$(mktemp -d)" || {
  echo "ERROR: could not create a private temporary directory for golangci-lint." >&2
  exit 1
}
GOLANGCI_STAGED=""
trap 'rm -rf "$GOLANGCI_TMP"; [ -z "$GOLANGCI_STAGED" ] || rm -f "$GOLANGCI_STAGED"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# golangci_lint_version <binary>: the release a golangci-lint binary reports, e.g. `2.14.0`.
golangci_lint_version() {
  "$1" version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# go_minor_is_newer <toolchain> <built-with>: 0 when the first Go version (`1.28.1`) is on a
# newer major.minor line than the second (`1.27.0`). A version that does not parse as numbers --
# empty, or a `devel` toolchain -- is never "newer", so an unknown never blocks a run.
go_minor_is_newer() {
  _gm_t_major=${1%%.*}
  _gm_t_minor=${1#*.}
  _gm_t_minor=${_gm_t_minor%%[!0-9]*}
  _gm_b_major=${2%%.*}
  _gm_b_minor=${2#*.}
  _gm_b_minor=${_gm_b_minor%%[!0-9]*}
  for _gm_part in "$_gm_t_major" "$_gm_t_minor" "$_gm_b_major" "$_gm_b_minor"; do
    case "$_gm_part" in
      '' | *[!0-9]*) return 1 ;;
    esac
  done
  [ "$_gm_t_major" -gt "$_gm_b_major" ] && return 0
  [ "$_gm_t_major" -eq "$_gm_b_major" ] && [ "$_gm_t_minor" -gt "$_gm_b_minor" ]
}

# The version was already pinned; the INSTALL was not. `wget -O- | sh` handed
# the runner -- holding the repository token -- to whatever bytes
# golangci-lint.run returned at that moment, and nothing verified either the
# installer script or the archive it went on to fetch. The release tarball is
# downloaded and checksum-verified directly instead, which is the same shape
# gitleaks, hadolint and shellcheck already use and removes the vendor's
# install script from the trust path entirely.
#
# A binary that already reports the pinned version is used as-is: first one on PATH, then the
# `./bin/golangci-lint` this script installs (or a consumer keeps for local runs). Only PATH used
# to be consulted, so unless `./bin` happened to be on PATH, every run downloaded and verified the
# archive again to replace a binary that was already the right one.
GOLANGCI_LINT=""
if command -v golangci-lint > /dev/null 2>&1 \
  && [ "$(golangci_lint_version golangci-lint)" = "$GOLANGCI_LINT_VERSION" ]; then
  GOLANGCI_LINT="golangci-lint"
elif [ -x ./bin/golangci-lint ] \
  && [ "$(golangci_lint_version ./bin/golangci-lint)" = "$GOLANGCI_LINT_VERSION" ]; then
  GOLANGCI_LINT="./bin/golangci-lint"
fi
if [ -z "$GOLANGCI_LINT" ]; then
  case "$(uname -m)" in
    x86_64)        GOLANGCI_ARCH="amd64"; GOLANGCI_DIGEST_ARCH="AMD64" ;;
    aarch64|arm64) GOLANGCI_ARCH="arm64"; GOLANGCI_DIGEST_ARCH="ARM64" ;;
    *)
      echo "ERROR: unsupported architecture for golangci-lint: $(uname -m)" >&2
      exit 1
      ;;
  esac

  GOLANGCI_SHA256=$(pinned_digest GOLANGCI_LINT "$GOLANGCI_DIGEST_ARCH") || exit 1
  GOLANGCI_DIR="golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${GOLANGCI_ARCH}"

  echo "Installing golangci-lint v$GOLANGCI_LINT_VERSION (linux/$GOLANGCI_ARCH)..."
  if ! download_verified \
    "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/${GOLANGCI_DIR}.tar.gz" \
    "$GOLANGCI_TMP/golangci-lint.tar.gz" \
    "$GOLANGCI_SHA256"; then
    exit 1
  fi

  if ! tar -xzf "$GOLANGCI_TMP/golangci-lint.tar.gz" -C "$GOLANGCI_TMP"; then
    echo "ERROR: failed to extract golangci-lint from the downloaded archive." >&2
    exit 1
  fi

  # Staged next to its destination under a name no other run holds, then renamed over it. A
  # rename within one filesystem is atomic, so a run that starts while another one installs
  # finds the old binary or the new one, never a partly written file.
  mkdir -p ./bin || exit 1
  GOLANGCI_STAGED="$(mktemp ./bin/.golangci-lint.XXXXXX)" || exit 1
  if ! cp "$GOLANGCI_TMP/${GOLANGCI_DIR}/golangci-lint" "$GOLANGCI_STAGED" \
    || ! chmod 0755 "$GOLANGCI_STAGED" \
    || ! mv -f "$GOLANGCI_STAGED" ./bin/golangci-lint; then
    echo "ERROR: failed to install golangci-lint into ./bin." >&2
    exit 1
  fi
  GOLANGCI_STAGED=""
  GOLANGCI_LINT="./bin/golangci-lint"
fi

# golangci-lint "supports Go versions lower or equal to the Go version used to compile it" (its
# FAQ), so a toolchain on a newer Go minor line than the binary's build is stopped here, naming
# both, instead of producing a wall of `typecheck` errors on the standard library that reads like
# findings in the code.
#
# Only the major.minor line is compared. The patch level of the build does not decide it:
# golangci-lint 2.13.2 and 2.14.0 were BOTH built with go1.27.0, yet 2.13.2 cannot read the export
# data go1.27.2 writes and 2.14.0 can. A rule that failed every newer patch would block a binary
# that works, and would not have singled out the one that did not. That case is caught after the
# run instead, by its error message.
#
# Both are kept as reported (`go1.27.0`, `go1.27.2`, or a `devel ...` toolchain) for the
# messages, and compared without the `go` prefix.
GOLANGCI_BUILT_WITH="$("$GOLANGCI_LINT" version 2> /dev/null \
  | sed -n 's/.* built with \(go[0-9][0-9.]*\).*/\1/p' | head -1)"
GO_TOOLCHAIN="$(go env GOVERSION 2> /dev/null)" || GO_TOOLCHAIN=""
echo "Using golangci-lint v$GOLANGCI_LINT_VERSION (built with ${GOLANGCI_BUILT_WITH:-an unknown Go})" \
  "with Go toolchain ${GO_TOOLCHAIN:-unknown}."
if go_minor_is_newer "${GO_TOOLCHAIN#go}" "${GOLANGCI_BUILT_WITH#go}"; then
  echo "::error::golangci-lint v$GOLANGCI_LINT_VERSION was built with $GOLANGCI_BUILT_WITH and" \
    "cannot analyse code for the $GO_TOOLCHAIN toolchain: it supports Go versions up to the one" \
    "it was built with. Bump GOLANGCI_LINT_VERSION in global/scripts/shared/pinned-versions.sh" \
    "to a release built with $GO_TOOLCHAIN or newer."
  rm -f "$mergedYamlFile"
  exit 1
fi

# How long the analysis may run before golangci-lint gives up. It was 10m, and with about twenty
# runs sharing one self-hosted host a clean analysis outran that and exited 4. That went unseen
# where the lint job was advisory (GitHub Actions, GitLab); now that a failed lint fails the run
# there too, it would turn a load spike into a red build. A run that finishes sooner is not
# slowed. Override it with `GOLANGCI_LINT_TIMEOUT`, e.g. in a self-hosted runner's `.env`. The
# analysis cache needs nothing here: golangci-lint keeps it in the user's cache directory, which
# a self-hosted GitHub runner already keeps between jobs.
GOLANGCI_LINT_TIMEOUT="${GOLANGCI_LINT_TIMEOUT:-30m}"

# The output is streamed AND kept, so a failure can be read back below. The status travels
# through a file because a POSIX pipeline reports the status of `tee`, not of the linter.
# The status file is read rather than defaulted: a run that was killed before writing it must
# fail, not pass.
{
  "$GOLANGCI_LINT" run \
    --config "merged.yml" \
    --color "always" \
    --timeout "$GOLANGCI_LINT_TIMEOUT" \
    --verbose \
    --allow-parallel-runners \
    --max-issues-per-linter 0 \
    --max-same-issues 0 $FIX_FLAG ./... 2>&1
  echo "$?" > "$GOLANGCI_TMP/status"
} | tee "$GOLANGCI_TMP/lint.log"
EXIT_CODE="$(cat "$GOLANGCI_TMP/status" 2> /dev/null)"
case "$EXIT_CODE" in
  '' | *[!0-9]*) EXIT_CODE=1 ;;
esac

# A binary whose export-data reader is older than the toolchain fails every package with
# `could not load export data ... export data version N is greater than maximum supported version
# M (typecheck)`. That is a tooling mismatch, not a finding, and the build Go of the binary does
# not reveal it in advance (see above), so it is named once the linter has said it.
if [ "$EXIT_CODE" -ne 0 ] && grep -q 'could not load export data' "$GOLANGCI_TMP/lint.log"; then
  echo "::error::golangci-lint v$GOLANGCI_LINT_VERSION (built with ${GOLANGCI_BUILT_WITH:-an unknown Go})" \
    "could not read the export data of Go toolchain ${GO_TOOLCHAIN:-unknown}, so the" \
    "\`typecheck\` errors above are a tooling mismatch, not findings in this code. Bump" \
    "GOLANGCI_LINT_VERSION in global/scripts/shared/pinned-versions.sh to a release that supports" \
    "${GO_TOOLCHAIN:-this toolchain}."
fi

# Exit code 4 is golangci-lint's timeout, not a finding. Say so: the log otherwise ends on a
# failure that reads as if the code were at fault.
if [ "$EXIT_CODE" -eq 4 ]; then
  echo "::error::golangci-lint ran out of time (--timeout $GOLANGCI_LINT_TIMEOUT) before it finished; no finding caused this failure. On a busy runner, raise GOLANGCI_LINT_TIMEOUT."
fi

rm "$mergedYamlFile"
exit "$EXIT_CODE"
