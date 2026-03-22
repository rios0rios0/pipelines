#!/usr/bin/env sh
set -e

version=$(git describe --tags --abbrev=0) || true
if [ -z "$version" ]; then version="latest"; echo "No version tag found in the repository, setting version to $version"; fi
echo "sonar.projectVersion=$version" >> sonar-project.properties
echo "Updated sonar.projectVersion to $version"

# Check if coverage files exist. If no coverage was produced by the test stage,
# override coverage report paths to avoid sonar-scanner failures when the project's
# sonar-project.properties references files that don't exist.
COVERAGE_FOUND=false
for pattern in \
  "coverage.out" \
  "coverage.txt" \
  "coverage/*.txt" \
  "coverage/*.xml" \
  "coverage/*.json" \
  "coverage/*.lcov" \
  "build/reports/coverage*" \
  "build/reports/jacoco/test/jacocoTestReport.xml" \
  "target/site/jacoco/jacoco.xml" \
  "TestResults/*.xml" \
  "TestResults/Cobertura.xml"; do
  # shellcheck disable=SC2086
  if ls $pattern 1>/dev/null 2>&1; then
    COVERAGE_FOUND=true
    break
  fi
done

if [ "$COVERAGE_FOUND" = "false" ]; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") - No coverage files found. Running SonarQube without coverage data."
  # Remove any coverage-related properties so sonar-scanner doesn't fail
  # looking for files that don't exist. An empty value disables the property.
  {
    echo "sonar.coverage.jacoco.xmlReportPaths="
    echo "sonar.javascript.lcov.reportPaths="
    echo "sonar.python.coverage.reportPaths="
    echo "sonar.go.coverage.reportPaths="
    echo "sonar.cs.opencover.reportsPaths="
    echo "sonar.cs.dotcover.reportsPaths="
    echo "sonar.cs.vscoveragexml.reportsPaths="
  } >> sonar-project.properties
  echo "Cleared coverage report path properties in sonar-project.properties."
else
  GO_REPORT_PATH=
  for p in coverage.out coverage.txt coverage/coverage.out coverage/coverage.txt coverage/*.txt coverage/*.out; do
    for f in $p; do
      [ -f "$f" ] || continue
      GO_REPORT_PATH="$f"
      break 2
    done
  done
  if [ -n "$GO_REPORT_PATH" ]; then
    echo "sonar.go.coverage.reportPaths=$GO_REPORT_PATH" >> sonar-project.properties
  fi

  # Auto-detect JaCoCo coverage reports (Gradle and Maven)
  JACOCO_REPORT_PATH=
  for p in build/reports/jacoco/test/jacocoTestReport.xml target/site/jacoco/jacoco.xml; do
    if [ -f "$p" ]; then
      JACOCO_REPORT_PATH="$p"
      break
    fi
  done
  if [ -n "$JACOCO_REPORT_PATH" ]; then
    echo "sonar.coverage.jacoco.xmlReportPaths=$JACOCO_REPORT_PATH" >> sonar-project.properties
  fi
fi

sonar-scanner
