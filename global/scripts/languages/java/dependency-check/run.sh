#!/usr/bin/env sh
# OWASP Dependency-Check runner shared by the GitHub Actions, GitLab CI and Azure DevOps Java pipelines.
#
# Dependency-Check resolves findings against a local H2 copy of the NVD (~350k CVE records). Building
# that copy is the expensive part, and the NVD API rate limits it *per source IP*: 5 requests per
# rolling 30s unauthenticated, 50 with an API key. Hosted CI runners share their egress IPs with every
# other project on the platform, so an unauthenticated bootstrap spends most of its time in 429 backoff
# and does not finish in a usable amount of time (~174 pages, observed at 5h+ and still climbing).
#
# Three things keep that from happening here:
#
#   1. The API key reaches the tool. Neither plugin picks NVD_API_KEY up from the environment on its
#      own -- Maven wants a `nvdApiKey*` user property, Gradle wants the `dependencyCheck.nvd.apiKey`
#      extension -- so exporting the variable alone is a no-op. Maven is handed the *name* of the
#      variable rather than its value: `-DnvdApiKey=...` would land the secret in `mvn -X` output
#      (GHSA-qqhq-8r2c-c3f5), and `-DnvdApiKeyEnvironmentVariable` exists for exactly this reason.
#
#   2. With no key, the NVD datafeed replaces the API. The feeds are a handful of gzipped JSON files
#      with no rate limit, so a keyless project still gets a usable scan instead of a hung job.
#
#   3. The database is pinned to one absolute, cacheable directory. The plugins otherwise default it
#      into ~/.m2 and $GRADLE_USER_HOME respectively, where the pipelines were not caching it.
#
# Environment:
#   NVD_API_KEY               NVD API key -- https://nvd.nist.gov/developers/request-an-api-key
#   NVD_DATAFEED_URL          NVD datafeed to use instead of the API; '{0}' expands to each year
#   NVD_VALID_FOR_HOURS       how long a cached database is reused before refreshing (default 24)
#   DEPENDENCY_CHECK_DATA_DIR where the H2 database lives (default ./.owasp) -- this is what to cache

set -e

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="dependency-check" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

# NIST's own JSON 2.0 feeds. Dependency-Check reconstructs the cache metadata from the `.meta` files
# these ship, so no self-hosted mirror is needed; point NVD_DATAFEED_URL at a `vulnz` mirror to use one.
DEFAULT_DATAFEED_URL='https://nvd.nist.gov/feeds/json/cve/2.0/nvdcve-2.0-{0}.json.gz'

# Both plugins reject a relative data directory.
dataDirectory="${DEPENDENCY_CHECK_DATA_DIR:-$(pwd)/.owasp}"
case "$dataDirectory" in
  /*) ;;
  *) dataDirectory="$(pwd)/$dataDirectory" ;;
esac
mkdir -p "$dataDirectory"

reportDirectory="$(pwd)/$REPORT_PATH"
validForHours="${NVD_VALID_FOR_HOURS:-24}"
datafeedUrl="${NVD_DATAFEED_URL:-}"

# Azure DevOps substitutes nothing for an undefined variable: `$(NVD_API_KEY)` arrives verbatim. Left
# alone it would be handed to the NVD as a key, earning 403s on every request -- worse than having no
# key at all, because the datafeed fallback below would never engage.
case "${NVD_API_KEY:-}" in
  '$('*) NVD_API_KEY='' ;;
esac
case "${NVD_DATAFEED_URL:-}" in
  '$('*) datafeedUrl='' ;;
esac
export NVD_API_KEY

if [ -n "${NVD_API_KEY:-}" ]; then
  echo "NVD API key found: updating over the authenticated NVD API (50 requests / 30s)."
else
  if [ -z "$datafeedUrl" ]; then
    datafeedUrl="$DEFAULT_DATAFEED_URL"
  fi
  echo "WARNING: NVD_API_KEY is not set."
  echo "WARNING: falling back to the NVD datafeed at $datafeedUrl."
  echo "WARNING: the unauthenticated NVD API is limited to 5 requests / 30s shared across every job"
  echo "WARNING: leaving this runner's IP, which is why a keyless API bootstrap does not finish."
  echo "WARNING: request a free key at https://nvd.nist.gov/developers/request-an-api-key and expose"
  echo "WARNING: it to this job as the NVD_API_KEY secret for faster and fresher scans."
fi

echo "Dependency-Check CVE database: $dataDirectory (reused for $validForHours hours before refreshing)."

runMaven() {
  # `nvdApiKeyEnvironmentVariable` passes the *name* of the variable, keeping the key itself out of the
  # process arguments and out of `mvn -X` output.
  set -- \
    '--batch-mode' \
    '--no-transfer-progress' \
    'org.owasp:dependency-check-maven:check' \
    "-DdataDirectory=$dataDirectory" \
    "-Dodc.outputDirectory=$reportDirectory" \
    '-Dformat=ALL' \
    "-DnvdValidForHours=$validForHours"

  if [ -n "${NVD_API_KEY:-}" ]; then
    set -- "$@" '-DnvdApiKeyEnvironmentVariable=NVD_API_KEY'
  fi
  if [ -n "$datafeedUrl" ]; then
    set -- "$@" "-DnvdDatafeedUrl=$datafeedUrl"
  fi

  mvn "$@"
}

runGradle() {
  gradleCommand='gradle'
  if [ -x './gradlew' ]; then
    gradleCommand='./gradlew'
  fi

  # The Gradle plugin reads its settings only from the `dependencyCheck` extension -- it ignores every
  # environment variable and system property. An init script writes them in without asking each
  # consuming project to edit its build.gradle.
  DEPENDENCY_CHECK_DATA_DIR="$dataDirectory" \
  DEPENDENCY_CHECK_REPORT_DIR="$reportDirectory" \
  NVD_DATAFEED_URL="$datafeedUrl" \
  NVD_VALID_FOR_HOURS="$validForHours" \
    "$gradleCommand" \
    --init-script "$SCRIPTS_DIR/global/scripts/languages/java/dependency-check/init.gradle" \
    dependencyCheckAnalyze
}

if [ -f 'pom.xml' ]; then
  runMaven
elif [ -f 'gradlew' ] || [ -f 'build.gradle' ] || [ -f 'build.gradle.kts' ]; then
  runGradle
else
  echo "ERROR: no 'pom.xml' and no Gradle build script found in $(pwd)."
  echo "ERROR: Dependency-Check runs against a Maven or Gradle project."
  exit 1
fi
