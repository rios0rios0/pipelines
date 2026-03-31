#!/usr/bin/env sh
# PMD provides SOURCE-LEVEL unused code detection (pattern matching on AST).
# For stricter BYTECODE-LEVEL analysis (whole-program call graph), use:
#   - SpotBugs (requires Gradle/Maven plugin: id 'com.github.spotbugs')
#   - ProGuard with -printusage (requires compiled bytecode + entry point config)

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="pmd" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/pmd.json"

PMD_VERSION="${PMD_VERSION:-7.13.0}"
PMD_DIR="/tmp/pmd-bin-$PMD_VERSION"
if [ ! -d "$PMD_DIR" ]; then
  echo "Installing PMD $PMD_VERSION..."
  wget -q "https://github.com/pmd/pmd/releases/download/pmd_releases%2F$PMD_VERSION/pmd-dist-$PMD_VERSION-bin.zip" -O /tmp/pmd.zip
  unzip -q /tmp/pmd.zip -d /tmp
  rm /tmp/pmd.zip
fi

echo "Running PMD unused code analysis..."
"$PMD_DIR/bin/pmd" check -d . \
  -R "category/java/bestpractices.xml/UnusedAssignment,category/java/bestpractices.xml/UnusedFormalParameter,category/java/bestpractices.xml/UnusedLocalVariable,category/java/bestpractices.xml/UnusedPrivateField,category/java/bestpractices.xml/UnusedPrivateMethod" \
  -f json --no-cache > "$fileName" 2>&1 || EXIT_CODE=$?

echo "PMD analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
