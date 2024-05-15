#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

customJsonFile="custom.json"
defaultJsonFile="$SCRIPTS_DIR/global/scripts/golangci-lint/.golangci.json"

if [ -f ".golangci.json" ]; then
  disableDefault=$(jq -r '.linters.disable' $defaultJsonFile)
  disableSpecific=$(jq -r '.linters.disable' .golangci.json)
  mergedDisable=$(echo "$disableDefault $disableSpecific" | jq -s 'add | unique')
  mergedLinters=$(jq -s '.[0].linters + .[1].linters | del(.disable)' $defaultJsonFile .golangci.json)
  result=$(jq --argjson disable "$mergedDisable" --argjson linters "$mergedLinters" -n '$linters * {"disable": $disable}')
  echo "{\"linters\": $result}" > $customJsonFile
else
  cp "$defaultJsonFile" $customJsonFile
fi

wget -O- -nv https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh
./bin/golangci-lint run \
  --config "custom.json" \
  --color "always" \
  --timeout "10m" \
  --print-resources-usage \
  --allow-parallel-runners \
  --max-issues-per-linter 0 \
  --max-same-issues 0 ./... || EXIT_CODE=$?

rm $customJsonFile
exit $EXIT_CODE
