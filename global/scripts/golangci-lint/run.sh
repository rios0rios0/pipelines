#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

mergedYamlFile="merged.yml"
defaultYamlFile="$SCRIPTS_DIR/global/scripts/golangci-lint/.golangci.yml"

if [ -f ".golangci.yml" ]; then
  python3 - "$defaultYamlFile" "$mergedYamlFile" << EOF
import sys, yaml

default_yaml_path = sys.argv[1]
merged_yaml_path = sys.argv[2]

with open(default_yaml_path, "r") as default_config_file:
    default_config = yaml.safe_load(default_config_file)
with open(".golangci.yml", "r") as repo_config_file:
    repo_config = yaml.safe_load(repo_config_file)

merged_config = {
    "linters": {
        "enable-all": True,
        "disable": list(
            set(
                default_config["linters"]["disable"]
                + repo_config["linters"].get("disable", [])
            )
        ),
    }
}

for linter in repo_config["linters"].get("enable", []):
    if linter in merged_config["linters"]["disable"]:
        merged_config["linters"]["disable"].remove(linter)

with open(merged_yaml_path, "w") as merged_config_file:
    yaml.dump(merged_config, merged_config_file)
EOF
else
  cp "$defaultYamlFile" $mergedYamlFile
fi

wget -O- -nv https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh
./bin/golangci-lint run \
  --config "merged.yml" \
  --color "always" \
  --timeout "10m" \
  --print-resources-usage \
  --allow-parallel-runners \
  --max-issues-per-linter 0 \
  --max-same-issues 0 ./... || EXIT_CODE=$?

rm $mergedYamlFile
exit $EXIT_CODE
