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
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

mergedYamlFile="merged.yml"
defaultYamlFile="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml"

if [ -f ".golangci.yml" ]; then
  # Start with the default config
  cp "$defaultYamlFile" "$mergedYamlFile"

  # Collect enabled linters from repo config and add new ones in a single operation
  repo_enabled=$(yq eval '.linters.enable[]?' ".golangci.yml" 2>/dev/null || true)
  if [ -n "$repo_enabled" ]; then
    to_enable=""
    for linter in $repo_enabled; do
      if [ -n "$linter" ]; then
        if ! yq eval ".linters.enable | contains([\"$linter\"])" "$mergedYamlFile" | grep -q true; then
          if [ -n "$to_enable" ]; then
            to_enable="$to_enable, \"$linter\""
          else
            to_enable="\"$linter\""
          fi
        fi
      fi
    done
    if [ -n "$to_enable" ]; then
      yq eval ".linters.enable += [${to_enable}]" -i "$mergedYamlFile"
    fi
  fi

  # Collect disabled linters and remove them all in a single operation
  repo_disabled=$(yq eval '.linters.disable[]?' ".golangci.yml" 2>/dev/null || true)
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
    yq eval "$filter" -i "$mergedYamlFile"
  fi

  # Merge linter settings using yq deep merge
  repo_settings=$(yq eval '.linters-settings // ""' ".golangci.yml" 2>/dev/null || true)
  if [ -n "$repo_settings" ] && [ "$repo_settings" != "" ] && [ "$repo_settings" != "null" ]; then
    yq eval-all 'select(fileIndex == 0) * {"linters-settings": select(fileIndex == 1).linters-settings}' "$mergedYamlFile" ".golangci.yml" > "$mergedYamlFile.tmp"
    mv "$mergedYamlFile.tmp" "$mergedYamlFile"
  fi
else
  cp "$defaultYamlFile" "$mergedYamlFile"
fi

wget -O- -nv https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh
./bin/golangci-lint run \
  --config "merged.yml" \
  --color "always" \
  --timeout "10m" \
  --verbose \
  --allow-parallel-runners \
  --max-issues-per-linter 0 \
  --max-same-issues 0 $FIX_FLAG ./... || EXIT_CODE=$?

rm "$mergedYamlFile"
exit $EXIT_CODE
