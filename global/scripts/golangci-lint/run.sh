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
defaultYamlFile="$SCRIPTS_DIR/global/scripts/golangci-lint/.golangci.yml"

if [ -f ".golangci.yml" ]; then
  # Start with the default config
  cp "$defaultYamlFile" "$mergedYamlFile"
  
  # Get enabled linters from repo config and add them to default
  repo_enabled=$(yq eval '.linters.enable[]?' ".golangci.yml" 2>/dev/null || true)
  if [ -n "$repo_enabled" ]; then
    echo "$repo_enabled" | while IFS= read -r linter; do
      if [ -n "$linter" ]; then
        # Check if linter is already in the default config
        if ! yq eval ".linters.enable | contains([\"$linter\"])" "$mergedYamlFile" | grep -q true; then
          # Add the linter to the enabled list
          yq eval ".linters.enable += [\"$linter\"]" -i "$mergedYamlFile"
        fi
      fi
    done
  fi
  
  # Handle disabled linters - remove them from enabled list
  repo_disabled=$(yq eval '.linters.disable[]?' ".golangci.yml" 2>/dev/null || true)
  if [ -n "$repo_disabled" ]; then
    echo "$repo_disabled" | while IFS= read -r linter; do
      if [ -n "$linter" ]; then
        # Remove the linter from the enabled list
        yq eval ".linters.enable = (.linters.enable | map(select(. != \"$linter\")))" -i "$mergedYamlFile"
      fi
    done
  fi
  
  # Merge linter settings using yq merge operation
  if yq eval '.linters-settings' ".golangci.yml" >/dev/null 2>&1; then
    # Ensure linters-settings section exists in output file
    yq eval '.linters-settings = (.linters-settings // {})' -i "$mergedYamlFile"
    # Use yq to merge the linters-settings from repo file into output file
    temp_file=$(mktemp)
    yq eval-all 'select(fileIndex == 0) * {"linters-settings": select(fileIndex == 1).linters-settings}' "$mergedYamlFile" ".golangci.yml" > "$temp_file"
    mv "$temp_file" "$mergedYamlFile"
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

rm $mergedYamlFile
exit $EXIT_CODE
