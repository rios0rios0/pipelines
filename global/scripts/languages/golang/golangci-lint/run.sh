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
# mikefarah/yq prints its own repository URL in the version banner; kislyuk/yq prints a bare
# `yq <version>`. Matching the URL is what separates them, since both answer `--version`.
if command -v yq > /dev/null 2>&1 && yq --version 2>&1 | grep -q 'mikefarah'; then
  YQ="yq"
fi
if [ -z "$YQ" ]; then
  mkdir -p ./bin
  # `--https-only` because the release URL redirects to GitHub's asset host: without it a
  # redirect could walk the download down to plain HTTP, where the binary about to be marked
  # executable is whatever answered.
  wget --https-only -O ./bin/yq -nv \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${YQ_OS}_${YQ_ARCH}"
  chmod +x ./bin/yq
  YQ="./bin/yq"
fi

# A merge step that fails must stop the run. Reporting the repository's own configuration as
# violations is worse than reporting nothing: it sends people to change correct code.
die() {
  echo "::error::golangci-lint config merge failed: $1"
  exit 1
}

mergedYamlFile="merged.yml"
defaultYamlFile="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml"

if [ -f ".golangci.yml" ]; then
  # Start with the default config
  cp "$defaultYamlFile" "$mergedYamlFile"

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

GOLANGCI_LINT_VERSION="v2.12.2"

GOLANGCI_LINT=""
if command -v golangci-lint > /dev/null 2>&1; then
  DETECTED_VERSION=$(golangci-lint version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ "$DETECTED_VERSION" = "${GOLANGCI_LINT_VERSION#v}" ]; then
    GOLANGCI_LINT="golangci-lint"
  fi
fi
if [ -z "$GOLANGCI_LINT" ]; then
  wget -O- -nv https://golangci-lint.run/install.sh | sh -s -- -b ./bin "${GOLANGCI_LINT_VERSION}"
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
