#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="codeql" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

CODEQL_LANGUAGE="${1:?Usage: run.sh <language> (e.g., go, python, java, javascript, csharp)}"
fileName="$(pwd)/$REPORT_PATH/codeql.sarif"

CODEQL_RAM="${CODEQL_RAM:-}"
CODEQL_THREADS="${CODEQL_THREADS:-1}"

RAM_FLAG=""
if [ -n "$CODEQL_RAM" ]; then
  RAM_FLAG="--ram=$CODEQL_RAM"
  echo "CodeQL RAM limit set to ${CODEQL_RAM} MB"
fi
THREADS_FLAG="--threads=$CODEQL_THREADS"
echo "CodeQL threads set to $CODEQL_THREADS"

CONFIG_FLAG=""
if [ -f "$(pwd)/codeql-config.yml" ]; then
  CONFIG_FLAG="--codescanning-config=$(pwd)/codeql-config.yml"
  echo "Using project CodeQL config: codeql-config.yml"
fi

# Load project-level configuration if available (e.g. for Go build environment)
if [ "$CODEQL_LANGUAGE" = "go" ]; then
  INIT_SCRIPT="config.sh"
  if [ -f "$INIT_SCRIPT" ]; then
    # shellcheck disable=SC1090
    . ./"$INIT_SCRIPT"
  else
    echo "The '$INIT_SCRIPT' file was not found, skipping..."
  fi
fi

# Install CodeQL CLI if not already available.
#
# GitHub only publishes Linux x86_64 CodeQL bundles (`codeql-bundle-linux64.tar.gz`).
# There is no native Linux ARM64 build of CodeQL — see
# https://github.com/github/codeql-action/issues/2839. Running the x86_64
# bundle directly on aarch64 fails with `Exec format error` on the bundled
# JRE (`tools/linux64/java/bin/java`) and a chain of confusing downstream
# errors (missing SARIF file, `jq` "No such file" warnings, `[: Illegal
# number`). Fail fast with an actionable message instead so the operator
# knows to switch the runner.
# Unlike the other tool scripts, CodeQL is intentionally NOT self-updated when
# already present: the CLI ships as a ~1 GB bundle with no lightweight version
# handle, so re-downloading it on every run of a persistent agent would cost far
# more than the staleness it avoids. Refresh it out-of-band instead.
if ! command -v codeql > /dev/null 2>&1; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)
      ;;
    aarch64|arm64)
      echo "ERROR: CodeQL has no native Linux ARM64 build — only x86_64 is published upstream." >&2
      echo "Detected architecture: $ARCH" >&2
      echo "Run this stage on an x86_64 runner, or set up qemu-user-static binfmt emulation before invoking the SAST stage." >&2
      exit 1
      ;;
    *)
      echo "ERROR: Unsupported architecture for CodeQL: $ARCH (only x86_64 is supported)." >&2
      exit 1
      ;;
  esac

  echo "Downloading CodeQL CLI bundle..."
  CODEQL_BUNDLE_URL="https://github.com/github/codeql-action/releases/latest/download/codeql-bundle-linux64.tar.gz"
  curl -fsSL "$CODEQL_BUNDLE_URL" -o /tmp/codeql-bundle.tar.gz
  mkdir -p "$HOME/.local/share"
  tar -xzf /tmp/codeql-bundle.tar.gz -C "$HOME/.local/share"
  # Symlink the CodeQL launcher into the user's ~/.local/bin (on PATH via the
  # shared preamble); the bundle itself lives under ~/.local/share — no root.
  ln -sf "$HOME/.local/share/codeql/codeql" "$HOME/.local/bin/codeql"
  rm /tmp/codeql-bundle.tar.gz
fi

echo "Creating CodeQL database for language: $CODEQL_LANGUAGE"
# shellcheck disable=SC2086
if ! codeql database create \
  --language="$CODEQL_LANGUAGE" \
  --source-root="$(pwd)" \
  $THREADS_FLAG \
  $CONFIG_FLAG \
  "$(pwd)/.codeql-db"; then
  echo "ERROR: 'codeql database create' failed for language '$CODEQL_LANGUAGE'." >&2
  rm -rf "$(pwd)/.codeql-db"
  exit 1
fi

echo "Running CodeQL analysis..."
# shellcheck disable=SC2086
if ! codeql database analyze \
  --format=sarifv2.1.0 \
  --output="$fileName" \
  $RAM_FLAG \
  $THREADS_FLAG \
  "$(pwd)/.codeql-db" \
  "$CODEQL_LANGUAGE-security-and-quality.qls"; then
  echo "ERROR: 'codeql database analyze' failed for language '$CODEQL_LANGUAGE'." >&2
  rm -rf "$(pwd)/.codeql-db"
  exit 1
fi

echo "CodeQL analysis complete. Results written to: $fileName"

# Clean up database
rm -rf "$(pwd)/.codeql-db"

# Refuse to proceed if the SARIF was not produced — without this guard the
# downstream `jq`/arithmetic pipeline emitted confusing cascading errors
# ("Could not open file", "[: Illegal number") that masked the real cause.
if [ ! -f "$fileName" ]; then
  echo "ERROR: CodeQL completed but SARIF report was not produced at $fileName." >&2
  exit 1
fi

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
