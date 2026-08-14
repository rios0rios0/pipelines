#!/usr/bin/env sh
set -e

# Test + coverage runner for the `30-tests` stage, for both toolchains.
#
# Produces the same three artefacts every other language runner in this
# repository produces, so the platform templates publish them identically:
#
#   build/reports/junit.xml       -- JUnit XML (Tests tab on all three platforms)
#   build/reports/cobertura.xml   -- Cobertura (Azure DevOps + GitLab coverage)
#   build/reports/lcov.info       -- raw LCOV (SonarQube reads this one directly)
#
# `coverage/lcov.info` is left in place as well, because that is the path
# SonarQube's `sonar.dart.lcov.reportPaths` and the community `sonar-flutter`
# plugin's `sonar.flutter.coverage.reportPath` both default to.
#
# Neither toolchain can emit JUnit on its own -- `dart test` and `flutter test`
# both offer a machine-readable JSON event stream and nothing else -- so
# `package:junitreport`'s `tojunit` converts the stream. It is the only
# maintained converter for this format, it is published on pub.dev, and it
# installs with the same `dart pub global activate` the rest of this family
# uses, so it costs no extra toolchain.
#
# The two CLIs spell the same flag differently: `dart test --reporter json` vs
# `flutter test --machine`. `flutter test` rejects `--reporter json` outright,
# which is why the invocation is branched rather than parameterised.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

dart_prepare_reports "dart-test"
REPORT_ROOT="$(dart_report_root)"
mkdir -p "$REPORT_ROOT"

JUNIT_FILE="$REPORT_ROOT/junit.xml"
COBERTURA_FILE="$REPORT_ROOT/cobertura.xml"
LCOV_FILE="coverage/lcov.info"
EVENTS_FILE="$DART_TOOL_REPORT_PATH/test-events.json"

dart_ensure_sdk

TEST_DIR="${DART_TEST_DIR:-test}"

# A repository with no test directory is a real situation (a freshly generated
# plugin, an example app, a package whose suite lives elsewhere), and `dart
# test` / `flutter test` both fail outright on it. Emit an empty-but-valid JUnit
# and pass, matching the opt-in contract the Terraform test tiers already
# establish -- but make it loud, and let a project that considers this a defect
# flip it with DART_REQUIRE_TESTS=true.
if [ ! -d "$TEST_DIR" ]; then
  if dart_is_truthy "${DART_REQUIRE_TESTS:-false}"; then
    echo "ERROR: no '$TEST_DIR' directory found and DART_REQUIRE_TESTS is set." >&2
    exit 1
  fi
  echo "WARNING: no '$TEST_DIR' directory found; nothing to run." >&2
  echo "         Set DART_REQUIRE_TESTS=true to make this a failure." >&2
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="dart-test"/>\n' > "$JUNIT_FILE"
  exit 0
fi

dart_pub_get
dart_global_activate junitreport tojunit

echo ""
echo "=========================================="
echo "RUNNING TESTS ($DART_TOOLCHAIN)"
echo "=========================================="

TEST_EXIT=0
if [ "$DART_TOOLCHAIN" = "flutter" ]; then
  # `--machine` and `--coverage` compose: the JSON event stream goes to stdout
  # while the tracefile is written to `coverage/lcov.info`.
  # shellcheck disable=SC2086
  if dart_is_dry_run; then
    dart_run flutter test --machine --coverage $DART_TEST_ARGS
  else
    dart_run flutter test --machine --coverage $DART_TEST_ARGS > "$EVENTS_FILE" || TEST_EXIT=$?
  fi
else
  dart_global_activate coverage format_coverage
  # shellcheck disable=SC2086
  if dart_is_dry_run; then
    dart_run dart test --reporter json --coverage=coverage $DART_TEST_ARGS
  else
    dart_run dart test --reporter json --coverage=coverage $DART_TEST_ARGS > "$EVENTS_FILE" || TEST_EXIT=$?
  fi

  # `dart test --coverage=<dir>` drops raw VM coverage JSON, not LCOV; only
  # `flutter test --coverage` produces the tracefile directly. Report on the
  # directories that actually exist so a CLI package (sources in `bin/`) is not
  # reported as 0% because only `lib/` was considered.
  REPORT_ON=""
  for candidate in ${DART_COVERAGE_REPORT_ON:-lib bin}; do
    [ -d "$candidate" ] && REPORT_ON="$REPORT_ON --report-on=$candidate"
  done
  [ -n "$REPORT_ON" ] || REPORT_ON="--report-on=lib"

  if ! dart_is_dry_run && [ -d coverage ]; then
    # shellcheck disable=SC2086
    format_coverage --lcov --in=coverage --out="$LCOV_FILE" --check-ignore $REPORT_ON \
      || echo "WARNING: could not format coverage data; continuing without a tracefile." >&2
  else
    # shellcheck disable=SC2086
    dart_run format_coverage --lcov --in=coverage --out="$LCOV_FILE" --check-ignore $REPORT_ON
  fi
fi

if dart_is_dry_run; then
  echo "DRY RUN: no tests were executed and no reports were written."
  exit 0
fi

echo ""
echo "=========================================="
echo "GENERATING REPORTS"
echo "=========================================="

# Reports are generated even when the suite failed -- a red build is exactly
# when someone needs to see which test failed and what the coverage was.
if [ -s "$EVENTS_FILE" ]; then
  tojunit --input "$EVENTS_FILE" --output "$JUNIT_FILE" \
    || echo "WARNING: 'tojunit' could not convert the test event stream." >&2
fi

if [ ! -s "$JUNIT_FILE" ]; then
  echo "WARNING: no JUnit report was produced; writing an empty one." >&2
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="dart-test"/>\n' > "$JUNIT_FILE"
fi

COVERAGE_EXIT=0
if [ -s "$LCOV_FILE" ]; then
  cp "$LCOV_FILE" "$REPORT_ROOT/lcov.info"
  python3 "$SCRIPTS_DIR/global/scripts/languages/dart/test/lcov_to_cobertura.py" \
    "$LCOV_FILE" "$COBERTURA_FILE" "." || COVERAGE_EXIT=$?
else
  echo "WARNING: no coverage tracefile at '$LCOV_FILE'; skipping the Cobertura report." >&2
fi

echo ""
echo "JUnit:     $JUNIT_FILE"
[ -f "$COBERTURA_FILE" ] && echo "Cobertura: $COBERTURA_FILE"
[ -f "$REPORT_ROOT/lcov.info" ] && echo "LCOV:      $REPORT_ROOT/lcov.info"

# The suite's own verdict wins over the coverage gate's: a failing test is the
# more important thing to report, and reporting the coverage shortfall instead
# would send someone chasing the wrong problem.
if [ "$TEST_EXIT" -ne 0 ]; then
  exit "$TEST_EXIT"
fi
exit "$COVERAGE_EXIT"
