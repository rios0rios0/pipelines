#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

CODEQL_LANGUAGE="${1:?Usage: run.sh <language> (e.g., go, python, java, javascript, csharp)}"
fileName="$(pwd)/$REPORT_PATH/codeql.sarif"

# Install CodeQL CLI if not already available
if ! command -v codeql > /dev/null 2>&1; then
  echo "Downloading CodeQL CLI bundle..."
  CODEQL_BUNDLE_URL="https://github.com/github/codeql-action/releases/latest/download/codeql-bundle-linux64.tar.gz"
  curl -fsSL "$CODEQL_BUNDLE_URL" -o /tmp/codeql-bundle.tar.gz
  tar -xzf /tmp/codeql-bundle.tar.gz -C /tmp
  export PATH="/tmp/codeql:$PATH"
  rm /tmp/codeql-bundle.tar.gz
fi

echo "Creating CodeQL database for language: $CODEQL_LANGUAGE"
codeql database create \
  --language="$CODEQL_LANGUAGE" \
  --source-root="$(pwd)" \
  "$(pwd)/.codeql-db"

echo "Running CodeQL analysis..."
codeql database analyze \
  --format=sarifv2.1.0 \
  --output="$fileName" \
  "$(pwd)/.codeql-db" \
  "$CODEQL_LANGUAGE-security-and-quality.qls"

echo "CodeQL analysis complete. Results written to: $fileName"

# Clean up database
rm -rf "$(pwd)/.codeql-db"

# Use default false positives file if the project doesn't provide one
fpFileExists=true
if [ ! -f ".codeql-false-positives" ]; then
  fpFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/codeql/.codeql-false-positives"
  cp "$defaultFile" .
fi

# Load false positive fingerprints
FP_FILE="$(pwd)/.codeql-false-positives"
FP_FILTER=$(grep -v '^\s*#' "$FP_FILE" | grep -v '^\s*$' | jq -R -s 'split("\n") | map(select(length > 0))')
FP_COUNT=$(echo "$FP_FILTER" | jq 'length')
if [ "$FP_COUNT" -gt 0 ]; then
  echo "Loaded $FP_COUNT false positive fingerprint(s) from .codeql-false-positives"
fi

# Count results excluding false positives matched by SARIF partialFingerprints
TOTAL_COUNT=$(jq '[.runs[].results[]] | length' "$fileName")
RESULT_COUNT=$(jq --argjson fp "$FP_FILTER" \
  '[.runs[].results[] | select(
    (.partialFingerprints // {} | to_entries | map(.value) | any(. as $h | $fp | any(. == $h))) | not
  )] | length' "$fileName")
SUPPRESSED=$((TOTAL_COUNT - RESULT_COUNT))

echo "CodeQL found $TOTAL_COUNT issue(s) total, $SUPPRESSED suppressed as false positive(s), $RESULT_COUNT remaining."
if [ "$RESULT_COUNT" -gt 0 ]; then
  jq -r --argjson fp "$FP_FILTER" \
    '.runs[].results[] | select(
      (.partialFingerprints // {} | to_entries | map(.value) | any(. as $h | $fp | any(. == $h))) | not
    ) | "  - \(.ruleId): \(.message.text) (\(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine))"' "$fileName"
  EXIT_CODE=1
fi

if [ "$fpFileExists" = false ]; then
  rm -f .codeql-false-positives
fi

exit ${EXIT_CODE:-0}
