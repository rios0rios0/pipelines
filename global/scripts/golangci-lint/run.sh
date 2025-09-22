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
  python3 - "$defaultYamlFile" "$mergedYamlFile" << EOF
import sys, yaml

with open(sys.argv[1], "r") as default_config_file:
    default_config = yaml.safe_load(default_config_file)
with open(".golangci.yml", "r") as repo_config_file:
    repo_config = yaml.safe_load(repo_config_file)

# Merge enabled linters
for linter in repo_config["linters"].get("enable", []):
    if linter not in default_config["linters"]["enable"]:
        default_config["linters"]["enable"].append(linter)

# Merge disabled linters
for linter in repo_config["linters"].get("disable", []):
    if linter in default_config["linters"]["enable"]:
        default_config["linters"]["enable"].remove(linter)

# Merge linter settings
for linter, settings in repo_config.get("linters-settings", {}).items():
    if settings is not None:
        if default_config.get("linters-settings") is None:
            default_config["linters-settings"] = {}
        default_config["linters-settings"][linter] = settings

with open(sys.argv[2], "w") as merged_config_file:
    yaml.dump(default_config, merged_config_file)
EOF
else
  cp "$defaultYamlFile" $mergedYamlFile
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
