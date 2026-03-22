#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deadcode" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

DEADCODE_LANGUAGE="${1:?Usage: run.sh <language> (e.g., go, python, javascript, java)}"
fileName="$(pwd)/$REPORT_PATH/deadcode.json"

# Use default false positives file if the project doesn't provide one
fpFileExists=true
if [ ! -f ".deadcode-ignore" ]; then
  fpFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/deadcode/.deadcode-ignore"
  if [ -f "$defaultFile" ]; then
    cp "$defaultFile" .
  else
    touch .deadcode-ignore
  fi
fi

run_go_deadcode() {
  echo "Running Go dead code analysis..."

  # Install deadcode if not already available
  if ! command -v deadcode > /dev/null 2>&1; then
    echo "Installing deadcode..."
    go install golang.org/x/tools/cmd/deadcode@latest
    export PATH="$(go env GOPATH)/bin:$PATH"
  fi

  # Load ignore patterns (package or function patterns to skip)
  IGNORE_PATTERNS=""
  if [ -s ".deadcode-ignore" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '#'*|'') continue ;;
      esac
      IGNORE_PATTERNS="$IGNORE_PATTERNS|$line"
    done < ".deadcode-ignore"
    IGNORE_PATTERNS="${IGNORE_PATTERNS#|}"
  fi

  # Run deadcode and capture output
  DEADCODE_OUTPUT=$(deadcode -json ./... 2>&1) || true

  if [ -n "$IGNORE_PATTERNS" ] && [ -n "$DEADCODE_OUTPUT" ]; then
    echo "$DEADCODE_OUTPUT" | grep -v -E "$IGNORE_PATTERNS" > "$fileName" || true
  else
    echo "${DEADCODE_OUTPUT:-[]}" > "$fileName"
  fi
}

run_python_deadcode() {
  echo "Running Python dead code analysis (vulture)..."

  # Install vulture if not already available
  if ! command -v vulture > /dev/null 2>&1; then
    echo "Installing vulture..."
    pip install vulture --quiet
  fi

  # Build allowlist argument
  ALLOWLIST_ARG=""
  if [ -s ".deadcode-ignore" ]; then
    ALLOWLIST_ARG="--ignore-names $(tr '\n' ',' < .deadcode-ignore | sed 's/,$//' | sed 's/#[^,]*,//g')"
  fi

  # Run vulture and convert output to JSON
  # shellcheck disable=SC2086
  VULTURE_OUTPUT=$(vulture . --min-confidence 80 $ALLOWLIST_ARG 2>&1) || true

  if [ -z "$VULTURE_OUTPUT" ]; then
    echo "[]" > "$fileName"
  else
    echo "$VULTURE_OUTPUT" | awk -F: '{
      gsub(/^ +| +$/, "", $4);
      printf "{\"file\":\"%s\",\"line\":%s,\"message\":\"%s\"}\n", $1, $2, $4
    }' | jq -s '.' > "$fileName"
  fi
}

run_javascript_deadcode() {
  echo "Running JavaScript/TypeScript dead code analysis (knip)..."

  chmod -R 777 "$REPORT_PATH" # DinD approach needs this line
  export CONTAINER_PATH="/src"

  # Check if project has knip config, otherwise use defaults
  KNIP_ARGS=""
  if [ ! -f "knip.json" ] && [ ! -f "knip.jsonc" ] && [ ! -f ".knip.json" ] && [ ! -f "knip.ts" ]; then
    KNIP_ARGS="--include files,exports,types,duplicates"
  fi

  # Run knip via Docker for isolation
  # shellcheck disable=SC2086
  docker run \
    -v "$(pwd):$CONTAINER_PATH" \
    --workdir "$CONTAINER_PATH" \
    --entrypoint sh \
    node:lts-alpine \
    -c "npm install -g knip typescript > /dev/null 2>&1 && knip --reporter json $KNIP_ARGS" > "$fileName" 2>&1 || true

  # Ensure valid JSON output
  if ! jq empty "$fileName" 2>/dev/null; then
    echo "[]" > "$fileName"
  fi
}

run_java_deadcode() {
  echo "Running Java dead code analysis (PMD)..."

  # Install PMD if not already available
  if ! command -v pmd > /dev/null 2>&1; then
    echo "Downloading PMD..."
    PMD_VERSION="7.9.0"
    curl -fsSL "https://github.com/pmd/pmd/releases/download/pmd_releases%2F$PMD_VERSION/pmd-dist-$PMD_VERSION-bin.zip" -o /tmp/pmd.zip
    unzip -q /tmp/pmd.zip -d /tmp
    export PATH="/tmp/pmd-bin-$PMD_VERSION/bin:$PATH"
    rm /tmp/pmd.zip
  fi

  # Use custom ruleset if available, otherwise use default dead code rules
  RULESET_ARG=""
  if [ -f ".deadcode-ruleset.xml" ]; then
    RULESET_ARG=".deadcode-ruleset.xml"
  else
    defaultRuleset="$SCRIPTS_DIR/global/scripts/tools/deadcode/.deadcode-ruleset.xml"
    if [ -f "$defaultRuleset" ]; then
      RULESET_ARG="$defaultRuleset"
    else
      RULESET_ARG="category/java/bestpractices.xml/UnusedPrivateField,category/java/bestpractices.xml/UnusedPrivateMethod,category/java/bestpractices.xml/UnusedLocalVariable,category/java/bestpractices.xml/UnusedFormalParameter"
    fi
  fi

  # Find source directories
  SRC_DIRS=""
  for dir in src/main/java src app; do
    if [ -d "$dir" ]; then
      SRC_DIRS="$SRC_DIRS,$dir"
    fi
  done
  SRC_DIRS="${SRC_DIRS#,}"

  if [ -z "$SRC_DIRS" ]; then
    echo "No Java source directories found, skipping."
    echo "[]" > "$fileName"
    return
  fi

  # Run PMD with dead code rules
  pmd check \
    -d "$SRC_DIRS" \
    -R "$RULESET_ARG" \
    -f json \
    -r "$fileName" || true

  # Ensure valid JSON output
  if ! jq empty "$fileName" 2>/dev/null; then
    echo "[]" > "$fileName"
  fi
}

# Route to the appropriate language handler
case "$DEADCODE_LANGUAGE" in
  go|golang)
    run_go_deadcode
    ;;
  python)
    run_python_deadcode
    ;;
  javascript|typescript|js|ts)
    run_javascript_deadcode
    ;;
  java)
    run_java_deadcode
    ;;
  *)
    echo "Error: Unsupported language '$DEADCODE_LANGUAGE'"
    echo "Supported languages: go, python, javascript, java"
    exit 1
    ;;
esac

# Count results
if jq empty "$fileName" 2>/dev/null; then
  RESULT_COUNT=$(jq 'if type == "array" then length elif type == "object" and has("files") then (.files | length) else 0 end' "$fileName" 2>/dev/null || echo "0")
else
  RESULT_COUNT=0
fi

echo "Dead code analysis complete. Found $RESULT_COUNT issue(s). Results written to: $fileName"

if [ "$fpFileExists" = false ]; then
  rm -f .deadcode-ignore
fi

# Non-zero exit if issues found (configurable via DEADCODE_STRICT)
if [ "${DEADCODE_STRICT:-false}" = "true" ] && [ "$RESULT_COUNT" -gt 0 ]; then
  exit 1
fi

exit 0
