#!/usr/bin/env sh

customJsonFile="custom.json"
defaultJsonFile="$SCRIPTS_DIR/global/scripts/golangci-lint/.golangci.json"

if [ -f ".golangci.json" ]; then
  jq -s '.[0] * .[1]' "$defaultJsonFile" ".golangci.json" > $customJsonFile
else
  cp "$defaultJsonFile" $customJsonFile
fi

wget -O- -nv https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh
./bin/golangci-lint run \
  --config "custom.json" \
  --color "always" \
  --timeout "5m" \
  --print-resources-usage \
  --allow-parallel-runners \
  --max-issues-per-linter 0 \
  --max-same-issues 0 ./... || EXIT_CODE=$?

rm $customJsonFile
exit $EXIT_CODE
