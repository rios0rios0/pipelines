#!/usr/bin/env sh
set -e

# Normalize a candidate SonarQube project key:
# - Replace whitespace and '/' with '_'
# - Replace any remaining unsupported characters with '_'
normalize_sonar_key() {
  printf '%s' "$1" | tr '[:space:]/' '_' | sed 's/[^A-Za-z0-9._:-]/_/g'
}

# Auto-derive sonar.projectKey if not already in properties file
if ! grep -Eq '^[[:space:]]*sonar\.projectKey[[:space:]]*=' sonar-project.properties 2>/dev/null; then
  key=""
  if [ -n "${SONAR_PROJECT_KEY:-}" ]; then
    key="$SONAR_PROJECT_KEY"
  elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    key=$(normalize_sonar_key "$GITHUB_REPOSITORY")
  elif [ -n "${SYSTEM_TEAMPROJECT:-}" ] && [ -n "${BUILD_REPOSITORY_NAME:-}" ]; then
    key=$(normalize_sonar_key "${SYSTEM_TEAMPROJECT}_${BUILD_REPOSITORY_NAME}")
  elif [ -n "${CI_PROJECT_PATH:-}" ]; then
    key=$(normalize_sonar_key "$CI_PROJECT_PATH")
  fi
  if [ -n "$key" ]; then
    echo "sonar.projectKey=$key" >> sonar-project.properties
    echo "Auto-derived sonar.projectKey=$key"
  fi
fi

# Auto-derive sonar.projectName if not already in properties file
if ! grep -Eq '^[[:space:]]*sonar\.projectName[[:space:]]*=' sonar-project.properties 2>/dev/null; then
  name=""
  if [ -n "${SONAR_PROJECT_NAME:-}" ]; then
    name="$SONAR_PROJECT_NAME"
  elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    name="${GITHUB_REPOSITORY#*/}"
  elif [ -n "${BUILD_REPOSITORY_NAME:-}" ]; then
    if [ -n "${SYSTEM_TEAMPROJECT:-}" ]; then
      name="${SYSTEM_TEAMPROJECT}/${BUILD_REPOSITORY_NAME}"
    else
      name="$BUILD_REPOSITORY_NAME"
    fi
  elif [ -n "${CI_PROJECT_NAME:-}" ]; then
    name="$CI_PROJECT_NAME"
  fi
  if [ -n "$name" ]; then
    echo "sonar.projectName=$name" >> sonar-project.properties
    echo "Auto-derived sonar.projectName=$name"
  fi
fi

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
  "build/reports/cobertura.xml" \
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

# SonarQube commonly runs as a single replica, so any restart — a node scale-down,
# a chart upgrade, an OOM — leaves its ingress answering `503 Service Temporarily
# Unavailable` for as long as the JVM and the embedded Elasticsearch take to boot.
# The scanner queries the server on its very first call, so it used to fail the
# build outright with:
#
#   ERROR Failed to query server version: GET .../api/server/version failed with
#   HTTP 503 Service Unavailable
#
# turning a transient infrastructure blip into a red pipeline. Wait for the server
# to report it can accept an analysis before scanning.
SONAR_WAIT_TIMEOUT="${SONAR_WAIT_TIMEOUT:-300}"
SONAR_WAIT_INTERVAL="${SONAR_WAIT_INTERVAL:-10}"
SONAR_MAX_ATTEMPTS="${SONAR_MAX_ATTEMPTS:-3}"

# Resolve the server URL from the environment, falling back to the properties file.
sonar_host_url() {
  if [ -n "${SONAR_HOST_URL:-}" ]; then
    printf '%s' "${SONAR_HOST_URL%/}"
    return 0
  fi
  sed -n 's/^[[:space:]]*sonar\.host\.url[[:space:]]*=[[:space:]]*//p' sonar-project.properties 2>/dev/null |
    tail -n 1 | sed 's#/*$##'
}

# Succeeds only when SonarQube is ready to accept an analysis. `STARTING`,
# `DB_MIGRATION_NEEDED` and `DB_MIGRATION_RUNNING` are all "not yet" — the scanner
# would be rejected in each of those states.
sonar_is_up() {
  _status_body=$(curl -sS --noproxy '*' --max-time 10 "$1/api/system/status" 2>/dev/null) || return 1
  case "$_status_body" in
    *'"status":"UP"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Blocks until SonarQube is up or the budget runs out. Exhausting the budget is
# deliberately NOT fatal here: the scanner runs anyway so the real error is what
# fails the build, rather than this wrapper masking it with a timeout message.
wait_for_sonar() {
  _url=$(sonar_host_url)
  if [ -z "$_url" ]; then
    echo "Neither SONAR_HOST_URL nor sonar.host.url is set; skipping the availability check."
    return 0
  fi

  _waited=0
  while ! sonar_is_up "$_url"; do
    if [ "$_waited" -ge "$SONAR_WAIT_TIMEOUT" ]; then
      echo "SonarQube at $_url did not become available within ${SONAR_WAIT_TIMEOUT}s; running the scanner anyway so the underlying error surfaces." >&2
      return 0
    fi
    echo "SonarQube at $_url is not ready yet (waited ${_waited}s of ${SONAR_WAIT_TIMEOUT}s); retrying in ${SONAR_WAIT_INTERVAL}s..."
    sleep "$SONAR_WAIT_INTERVAL"
    _waited=$((_waited + SONAR_WAIT_INTERVAL))
  done

  if [ "$_waited" -gt 0 ]; then
    echo "SonarQube became available after ${_waited}s."
  fi
  return 0
}

wait_for_sonar

# Retry ONLY when the server dropped out mid-analysis. A failure while the server
# is still up is a genuine one — a failed quality gate, a bad configuration, an
# unparseable report — and must surface on the first attempt instead of being
# retried three times and reported minutes late.
attempt=1
while :; do
  set +e
  sonar-scanner
  scanner_status=$?
  set -e

  if [ "$scanner_status" -eq 0 ]; then
    break
  fi

  scanner_url=$(sonar_host_url)
  if [ -z "$scanner_url" ] || sonar_is_up "$scanner_url"; then
    exit "$scanner_status"
  fi

  if [ "$attempt" -ge "$SONAR_MAX_ATTEMPTS" ]; then
    echo "SonarQube was still unreachable after ${SONAR_MAX_ATTEMPTS} attempts; giving up." >&2
    exit "$scanner_status"
  fi

  echo "SonarQube became unreachable during the analysis; waiting for it to come back (attempt ${attempt} of ${SONAR_MAX_ATTEMPTS})." >&2
  attempt=$((attempt + 1))
  wait_for_sonar
done
