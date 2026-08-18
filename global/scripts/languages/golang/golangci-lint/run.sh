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

# The version was already pinned; the INSTALL was not. `wget -O- | sh` handed
# the runner -- holding the repository token -- to whatever bytes
# golangci-lint.run returned at that moment, and nothing verified either the
# installer script or the archive it went on to fetch. The release tarball is
# downloaded and checksum-verified directly instead, which is the same shape
# gitleaks, hadolint and shellcheck already use and removes the vendor's
# install script from the trust path entirely.

GOLANGCI_LINT=""
if command -v golangci-lint > /dev/null 2>&1; then
  DETECTED_VERSION=$(golangci-lint version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ "$DETECTED_VERSION" = "$GOLANGCI_LINT_VERSION" ]; then
    GOLANGCI_LINT="golangci-lint"
  fi
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
    /tmp/golangci-lint.tar.gz \
    "$GOLANGCI_SHA256"; then
    exit 1
  fi

  mkdir -p ./bin
  if ! tar -xzf /tmp/golangci-lint.tar.gz -C /tmp; then
    echo "ERROR: failed to extract golangci-lint from /tmp/golangci-lint.tar.gz." >&2
    rm -f /tmp/golangci-lint.tar.gz
    exit 1
  fi
  mv "/tmp/${GOLANGCI_DIR}/golangci-lint" ./bin/golangci-lint
  chmod +x ./bin/golangci-lint
  rm -rf /tmp/golangci-lint.tar.gz "/tmp/${GOLANGCI_DIR}"
  GOLANGCI_LINT="./bin/golangci-lint"
fi

# Initialised because it is only assigned when the run fails: left unset, `exit $EXIT_CODE`
# expands to a bare `exit` and returns the status of the preceding `rm` instead.
EXIT_CODE=0
"$GOLANGCI_LINT" run \
  --config "merged.yml" \
  --color "always" \
  --timeout "10m" \
  --verbose \
  --allow-parallel-runners \
  --max-issues-per-linter 0 \
  --max-same-issues 0 $FIX_FLAG ./... || EXIT_CODE=$?

rm "$mergedYamlFile"
exit $EXIT_CODE
