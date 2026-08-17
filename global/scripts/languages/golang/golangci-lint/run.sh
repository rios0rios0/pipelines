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

# Fetches $1 into $2 over HTTPS only -- including redirects, which is the point: the release URL
# redirects to GitHub's asset host, and the file being fetched is about to be marked executable,
# so a redirect walked down to plain HTTP would hand execution to whatever answered. `curl` is
# preferred but not assumed; a runner carrying only one of the two is common, and a self-hosted
# runner may carry neither, which is why the caller reports the failure instead of continuing.
download() {
  if command -v curl > /dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --location --fail --silent --show-error --output "$2" "$1"
  elif command -v wget > /dev/null 2>&1; then
    wget --https-only -O "$2" -nv "$1"
  else
    echo 'neither curl nor wget is available' >&2
    return 127
  fi
}

# `yq` is two unrelated programs sharing a name: this script needs mikefarah/yq (Go, `yq eval
# '<expression>' <file>`), while many distributions and `pip` ship kislyuk/yq (a jq wrapper that
# reads the expression as a filename and rejects `eval` outright). Accepting whichever one is on
# PATH is how a project's `.golangci.yml` silently stopped being applied: every merge below used
# to end in `2>/dev/null || true`, so the wrong `yq` produced empty output instead of an error,
# the repository's `enable`, `disable` and `linters-settings` were all dropped, and the run
# carried on against the shared default alone. The symptom is a wall of findings for linters the
# project had deliberately disabled or retuned -- with nothing anywhere saying the config was
# ignored. Resolve the right binary up front, exactly as golangci-lint itself is resolved below.
YQ_VERSION="v4.47.1"

case "$(uname -s)" in
  Darwin) YQ_OS='darwin' ;;
  *) YQ_OS='linux' ;;
esac
case "$(uname -m)" in
  aarch64 | arm64) YQ_ARCH='arm64' ;;
  *) YQ_ARCH='amd64' ;;
esac

YQ=""

# Called only from the branch that has a config to merge. A repository without `.golangci.yml`
# copies the shared default verbatim and never reads `$YQ`, so resolving it there would add a
# network dependency -- and a way for the run to fail -- to the one case that needs neither.
resolve_yq() {
  # mikefarah/yq prints its own repository URL in the version banner; kislyuk/yq prints a bare
  # `yq <version>`. Matching the URL is what separates them, since both answer `--version`.
  if command -v yq > /dev/null 2>&1 && yq --version 2>&1 | grep -q 'mikefarah'; then
    YQ="yq"
    return 0
  fi
  mkdir -p ./bin
  download \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${YQ_OS}_${YQ_ARCH}" \
    ./bin/yq \
    || die "could not download mikefarah/yq ${YQ_VERSION} for ${YQ_OS}/${YQ_ARCH}"
  chmod +x ./bin/yq || die 'could not make the downloaded yq executable'
  YQ="./bin/yq"
  return 0
}

mergedYamlFile="merged.yml"
defaultYamlFile="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml"

if [ -f ".golangci.yml" ]; then
  # Start with the default config
  cp "$defaultYamlFile" "$mergedYamlFile"

  resolve_yq

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
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

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
