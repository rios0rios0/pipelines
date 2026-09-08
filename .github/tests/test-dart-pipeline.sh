#!/usr/bin/env bash
# The assertion helpers take their condition as a STRING and `eval` it, so
# ShellCheck cannot see that CMD / COV_OUT / MK_OUT / PY_OUT are read, and reports
# them as unused. They are not. A file-wide directive is only honoured before the
# first command, which is why it sits here rather than beside each assignment.
# shellcheck disable=SC2034
set -e

# Validation for the Dart / Flutter pipeline: the scripts under
# `global/scripts/languages/dart/`, the Dart Semgrep ruleset, and the templates
# on all three platforms.
#
# Five classes of assertion, each pinning something that would otherwise fail
# silently or late:
#
#   1. STRUCTURAL -- every stage is wired on GitHub Actions, GitLab CI and Azure
#      DevOps, and every template points at a script that exists. A stage added
#      to one platform and forgotten on the other two is the most likely
#      regression in this repository, and nothing else in CI would catch it:
#      each file is valid YAML on its own.
#
#   2. TOOLCHAIN DISPATCH -- the same script must drive `flutter` on a Flutter
#      project and `dart` on a pure Dart one, chosen from `pubspec.yaml`. Getting
#      this backwards produces failures deep inside the widget-test bindings that
#      name nothing useful, so it is asserted on the argv each script builds.
#
#   3. TOOL-GAP -- CodeQL has no Dart extractor and the Semgrep Registry
#      publishes no Dart rules. Both gaps are handled by deliberate ABSENCES and
#      SUBSTITUTIONS, which are exactly the kind of decision a later "let's make
#      this consistent with the other languages" edit silently undoes. These
#      cases fail if a `codeql` job reappears in a Dart template, or if the
#      shipped Dart Semgrep ruleset goes missing.
#
#   4. REPORT CONVERSION -- Dart emits coverage as LCOV and its analyzer output
#      as a pipe-delimited line format; two of the three platforms can read
#      neither. The converters are exercised against fixtures covering the cases
#      a naive implementation gets wrong (escaped pipes, repeated `SF:` records).
#
#   5. SECURITY -- no credential may reach a recorded command line. Every report
#      directory here is published as a job artifact on all three platforms, so a
#      token on argv would be both visible in `ps` on a self-hosted runner AND
#      persisted into a downloadable artifact. Each case feeds a distinctive
#      sentinel and greps the whole report tree for it. This assertion must never
#      be relaxed.
#
# The whole suite runs OFFLINE with no Dart SDK, no Flutter SDK and no network:
# the run scripts are driven under `DART_DRY_RUN=true`, which resolves and
# records every command without installing or executing anything. Semgrep
# assertions that need the binary are skipped when it is absent (the repository's
# CI job does not install it), but the ruleset's presence and YAML validity are
# always checked.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR

DART_DIR="$SCRIPTS_DIR/global/scripts/languages/dart"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

assert_true() {
  local description="$1"
  local condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_equals() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    echo -e "${RED}        expected: $expected${NC}"
    echo -e "${RED}        actual:   $actual${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

skip() {
  echo -e "${YELLOW}  SKIP: $1${NC}"
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# make_project <dir> <flutter|dart>
#
# Build a minimal but realistic package. The Flutter variant declares
# `flutter:\n    sdk: flutter` under `dependencies`, which is the marker the
# toolchain detection actually keys on.
make_project() {
  local dir="$WORK_DIR/$1"
  local kind="$2"
  rm -rf "${dir:?}"
  mkdir -p "$dir/lib" "$dir/test" "$dir/bin"

  if [[ "$kind" == "flutter" ]]; then
    cat > "$dir/pubspec.yaml" <<'EOF'
name: sample_app
description: A sample Flutter application.
version: 1.4.2+7
environment:
  sdk: '>=3.5.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.0
dev_dependencies:
  flutter_test:
    sdk: flutter
EOF
  else
    cat > "$dir/pubspec.yaml" <<'EOF'
name: sample_cli
description: A sample Dart command-line application.
version: 2.0.1
environment:
  sdk: '>=3.5.0 <4.0.0'
dependencies:
  args: ^2.4.0
dev_dependencies:
  test: ^1.24.0
EOF
  fi

  printf 'void main() {}\n' > "$dir/lib/${1}.dart"
  printf 'void main() {}\n' > "$dir/test/sample_test.dart"
  printf 'void main() {}\n' > "$dir/bin/sample_cli.dart"
  : > "$dir/pubspec.lock"
  : > "$dir/analysis_options.yaml"
  printf '%s' "$dir"
}

# run_dart <project-dir> <script> [env assignments...]
#
# Drive one runner in dry-run mode and expose:
#   STATUS -- the exit code
#   CMD    -- the recorded command journal, newline-joined
run_dart() {
  local project="$1"
  local script="$2"
  shift 2

  STATUS=0
  (
    cd "$project"
    env DART_DRY_RUN=true SCRIPTS_DIR="$SCRIPTS_DIR" "$@" \
      sh "$DART_DIR/$script/run.sh" > "$WORK_DIR/last.log" 2>&1
  ) || STATUS=$?

  CMD="$(cat "$project"/build/reports/*/command.txt 2>/dev/null || true)"
}

assert_no_leak() {
  local description="$1"
  local project="$2"
  local sentinel="$3"
  if grep -rqF "$sentinel" "$project/build/reports" 2>/dev/null; then
    echo -e "${RED}  FAIL: $description (sentinel found in the published report tree)${NC}"
    grep -rlF "$sentinel" "$project/build/reports" 2>/dev/null | sed 's/^/        /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

echo "=========================================="
echo "Dart / Flutter pipeline validation"
echo "=========================================="

# ---------------------------------------------------------------------------
echo ""
echo "--- 1. Scripts exist, are executable, and declare POSIX sh ---"
# ---------------------------------------------------------------------------

for script in setup format analyze test unused sca build publish; do
  assert_true "$script/run.sh exists" "[[ -f '$DART_DIR/$script/run.sh' ]]"
  assert_true "$script/run.sh is executable" "[[ -x '$DART_DIR/$script/run.sh' ]]"
  assert_true "$script/run.sh declares '#!/usr/bin/env sh'" \
    "head -1 '$DART_DIR/$script/run.sh' | grep -q '^#!/usr/bin/env sh$'"
done

# `common.sh` is sourced, never executed -- the same contract the deploy family
# follows. An executable bit on it invites someone to run it, which does nothing.
assert_true "common.sh exists" "[[ -f '$DART_DIR/common.sh' ]]"
assert_true "common.sh is NOT executable (it is sourced, never run)" \
  "[[ ! -x '$DART_DIR/common.sh' ]]"
assert_true "common.sh is not named run.sh (so the CI permission check skips it)" \
  "[[ ! -f '$DART_DIR/common.sh/run.sh' ]]"

for helper in analyze/dart_analyze_report.py test/lcov_to_cobertura.py test/lcov_to_markdown.py \
              test/filter_test_events.py; do
  assert_true "$helper exists" "[[ -f '$DART_DIR/$helper' ]]"
  assert_true "$helper is valid Python" \
    "python3 -m py_compile '$DART_DIR/$helper'"
done

# ---------------------------------------------------------------------------
echo ""
echo "--- 2. Toolchain dispatch: Flutter project ---"
# ---------------------------------------------------------------------------

FLUTTER_PROJECT="$(make_project flutterapp flutter)"

run_dart "$FLUTTER_PROJECT" analyze
assert_true "flutter: dependencies are resolved with 'flutter pub get'" \
  "grep -qx 'flutter pub get' <<< \"\$CMD\""
# `flutter analyze` has no `--format` option (flutter/flutter#95090), so the
# machine-readable path must go through the SDK's bundled `dart`.
assert_true "flutter: analysis runs 'dart analyze --format=machine', not 'flutter analyze'" \
  "grep -qx 'dart analyze --format=machine .' <<< \"\$CMD\""
assert_true "flutter: 'flutter analyze' is never invoked" \
  "! grep -q 'flutter analyze' <<< \"\$CMD\""

run_dart "$FLUTTER_PROJECT" test
assert_true "flutter: tests run 'flutter test --machine --coverage'" \
  "grep -qx 'flutter test --machine --coverage' <<< \"\$CMD\""
assert_true "flutter: the JUnit converter is installed" \
  "grep -qx 'dart pub global activate junitreport' <<< \"\$CMD\""
# `flutter test --coverage` writes `coverage/lcov.info` itself; running
# format_coverage over it would be a no-op at best.
assert_true "flutter: format_coverage is NOT run (flutter emits LCOV directly)" \
  "! grep -q 'format_coverage' <<< \"\$CMD\""

run_dart "$FLUTTER_PROJECT" build
assert_true "flutter: the default build target is an APK" \
  "grep -q 'flutter build apk --release' <<< \"\$CMD\""
assert_true "flutter: --build-name is derived from pubspec.yaml, without the build metadata" \
  "grep -q 'build-name=1.4.2' <<< \"\$CMD\""

# ---------------------------------------------------------------------------
echo ""
echo "--- 3. Toolchain dispatch: pure Dart project ---"
# ---------------------------------------------------------------------------

DART_PROJECT="$(make_project dartcli dart)"

run_dart "$DART_PROJECT" analyze
assert_true "dart: dependencies are resolved with 'dart pub get'" \
  "grep -qx 'dart pub get' <<< \"\$CMD\""
assert_true "dart: 'flutter' is never invoked on a non-Flutter package" \
  "! grep -q '^flutter ' <<< \"\$CMD\""

run_dart "$DART_PROJECT" test
# `dart test` spells the reporter flag differently from `flutter test`, and
# rejects the other one outright.
assert_true "dart: tests run 'dart test --reporter json'" \
  "grep -q 'dart test --reporter json --coverage=coverage' <<< \"\$CMD\""
assert_true "dart: raw VM coverage is converted to LCOV with format_coverage" \
  "grep -q 'format_coverage --lcov' <<< \"\$CMD\""
# A CLI package keeps its sources in bin/, so reporting only on lib/ would show
# it as 0% covered.
assert_true "dart: coverage reports on both lib/ and bin/ when both exist" \
  "grep -q -- '--report-on=lib' <<< \"\$CMD\" && grep -q -- '--report-on=bin' <<< \"\$CMD\""

run_dart "$DART_PROJECT" build
assert_true "dart: the default build target is a native executable" \
  "grep -q 'dart compile exe' <<< \"\$CMD\""
assert_true "dart: the entry point is the bin/ file named after the package" \
  "grep -q 'bin/sample_cli.dart' <<< \"\$CMD\""

# A library with no bin/ has nothing to build and must not fail for it.
LIB_PROJECT="$(make_project dartlib dart)"
rm -rf "${LIB_PROJECT:?}/bin"
run_dart "$LIB_PROJECT" build
assert_true "dart: a package with no bin/ exits cleanly instead of failing" "[[ $STATUS -eq 0 ]]"
assert_true "dart: a package with no bin/ builds nothing" \
  "! grep -q 'dart compile' <<< \"\$CMD\""

# EVERY `dart compile` target needs an entry point, and none of them fails
# usefully without one: an empty path makes the compiler complain about a file it
# was never given, and the snapshot targets derive their OUTPUT name from it too,
# so an empty value silently produces `build/.aot`. The guard originally lived in
# `exe` alone; these cases keep `js` and `aot-snapshot` from drifting back.
for target in exe js aot-snapshot; do
  STATUS=0
  (cd "$LIB_PROJECT" && env DART_DRY_RUN=true SCRIPTS_DIR="$SCRIPTS_DIR" \
    sh "$DART_DIR/build/run.sh" "$target" > "$WORK_DIR/entry.$target.log" 2>&1) || STATUS=$?
  assert_true "build: the '$target' target fails when no entry point can be resolved" \
    "[[ $STATUS -eq 1 ]]"
  assert_true "build: the '$target' failure names the target it was building" \
    "grep -q \"no entry point found for the '$target' target\" '$WORK_DIR/entry.$target.log'"
done

# ---------------------------------------------------------------------------
echo ""
echo "--- 4. Explicit toolchain override ---"
# ---------------------------------------------------------------------------

run_dart "$DART_PROJECT" analyze DART_TOOLCHAIN=flutter
assert_true "DART_TOOLCHAIN=flutter overrides the pubspec detection" \
  "grep -qx 'flutter pub get' <<< \"\$CMD\""

run_dart "$FLUTTER_PROJECT" analyze DART_TOOLCHAIN=dart
assert_true "DART_TOOLCHAIN=dart overrides the pubspec detection" \
  "grep -qx 'dart pub get' <<< \"\$CMD\""

run_dart "$FLUTTER_PROJECT" analyze DART_TOOLCHAIN=auto
assert_true "DART_TOOLCHAIN=auto falls back to detection rather than being taken literally" \
  "grep -qx 'flutter pub get' <<< \"\$CMD\""

# ---------------------------------------------------------------------------
echo ""
echo "--- 5. Missing test directory is a skip, not a crash ---"
# ---------------------------------------------------------------------------

NOTESTS="$(make_project notests dart)"
rm -rf "${NOTESTS:?}/test"
STATUS=0
(cd "$NOTESTS" && env SCRIPTS_DIR="$SCRIPTS_DIR" sh "$DART_DIR/test/run.sh" > "$WORK_DIR/notests.log" 2>&1) || STATUS=$?
assert_true "a package with no test/ directory passes rather than failing" "[[ $STATUS -eq 0 ]]"
assert_true "a package with no test/ directory still gets a valid JUnit report" \
  "python3 -c \"import xml.dom.minidom as m; m.parse('$NOTESTS/build/reports/junit.xml')\""
assert_true "the skip is reported loudly rather than silently" \
  "grep -q 'no .* directory found' '$WORK_DIR/notests.log'"

STATUS=0
(cd "$NOTESTS" && env SCRIPTS_DIR="$SCRIPTS_DIR" DART_REQUIRE_TESTS=true sh "$DART_DIR/test/run.sh" > /dev/null 2>&1) || STATUS=$?
assert_true "DART_REQUIRE_TESTS=true turns the skip into a failure" "[[ $STATUS -eq 1 ]]"

# ---------------------------------------------------------------------------
echo ""
echo "--- 6. Credentials never reach a recorded command line ---"
# ---------------------------------------------------------------------------

PUB_PROJECT="$(make_project pubpkg dart)"
SENTINEL='fixture-pub-credential-placeholder'

STATUS=0
(cd "$PUB_PROJECT" && env DART_DRY_RUN=true SCRIPTS_DIR="$SCRIPTS_DIR" \
  PUB_TOKEN="$SENTINEL" sh "$DART_DIR/publish/run.sh" > /dev/null 2>&1) || STATUS=$?
CMD="$(cat "$PUB_PROJECT"/build/reports/*/command.txt 2>/dev/null || true)"
assert_true "publish: the dry run validates the package" \
  "grep -q 'dart pub publish --dry-run' <<< \"\$CMD\""
assert_no_leak "publish: the pub token is never recorded" "$PUB_PROJECT" "$SENTINEL"

# The real publish path is the one that must pass the token's NAME, never its
# value. `--env-var PUB_TOKEN` is what makes that possible; a `--token` style
# flag would put the credential on argv and into the published artifact.
PUB2="$(make_project pubpkg2 dart)"
STATUS=0
(cd "$PUB2" && env SCRIPTS_DIR="$SCRIPTS_DIR" PUB_TOKEN="$SENTINEL" DART_TOOLCHAIN=dart \
  sh -c 'set -e
    . "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"
    dart_prepare_reports "dart-publish"
    DART_DRY_RUN=true dart_run dart pub token add https://pub.dev --env-var PUB_TOKEN' \
  > /dev/null 2>&1) || STATUS=$?
CMD="$(cat "$PUB2"/build/reports/*/command.txt 2>/dev/null || true)"
assert_true "publish: authentication passes the variable NAME, not its value" \
  "grep -q -- '--env-var PUB_TOKEN' <<< \"\$CMD\""
assert_no_leak "publish: the token value never appears in the report tree" "$PUB2" "$SENTINEL"

# `publish_to: none` marks a package that must never be uploaded anywhere.
NOPUB="$(make_project nopub dart)"
printf 'publish_to: none\n' >> "$NOPUB/pubspec.yaml"
STATUS=0
(cd "$NOPUB" && env SCRIPTS_DIR="$SCRIPTS_DIR" PUB_TOKEN="$SENTINEL" \
  sh "$DART_DIR/publish/run.sh" > "$WORK_DIR/nopub.log" 2>&1) || STATUS=$?
assert_true "publish: 'publish_to: none' short-circuits before any pub command" "[[ $STATUS -eq 0 ]]"
assert_true "publish: 'publish_to: none' is reported as a deliberate skip" \
  "grep -q 'not meant to be published' '$WORK_DIR/nopub.log'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 7. LCOV to Cobertura conversion ---"
# ---------------------------------------------------------------------------

cat > "$WORK_DIR/lcov.info" <<'EOF'
SF:lib/main.dart
DA:1,1
DA:2,0
DA:3,5
BRDA:3,0,0,1
BRDA:3,0,1,-
end_of_record
SF:lib/src/util.dart
DA:10,2
DA:11,2
end_of_record
SF:lib/main.dart
DA:2,3
DA:4,0
end_of_record
EOF

COV_OUT="$(python3 "$DART_DIR/test/lcov_to_cobertura.py" "$WORK_DIR/lcov.info" "$WORK_DIR/cobertura.xml" . 2>&1)"
assert_true "the Cobertura report is well-formed XML" \
  "python3 -c \"import xml.dom.minidom as m; m.parse('$WORK_DIR/cobertura.xml')\""
# A repeated `SF:` record for the same file is what a multi-entry-point suite
# produces. Replacing rather than merging would report only the last suite's
# hits -- here that would turn 5/6 into 1/2.
assert_true "repeated SF: records for one file are merged, not replaced" \
  "grep -q 'COVERAGE_PERCENT=83.33%' <<< \"\$COV_OUT\""
assert_true "the merged file has all four of its lines" \
  "grep -c '<line number=' '$WORK_DIR/cobertura.xml' | grep -qx '6'"
assert_true "a line covered by only the second record counts as covered" \
  "grep -q '<line number=\"2\" hits=\"3\"/>' '$WORK_DIR/cobertura.xml'"
assert_true "branch coverage is recomputed from the BRDA rows" \
  "grep -q 'branches-covered=\"1\" branches-valid=\"2\"' '$WORK_DIR/cobertura.xml'"
# The `<package>` branch rate must be AGGREGATED, not hard-coded. A fixed `0.0`
# disagrees with the `<class>` rates inside that same package and with the
# document totals, so a consumer that aggregates per package reads fully
# branch-covered code as having none.
assert_true "the package-level branch rate is aggregated, not hard-coded to zero" \
  "! grep -q '<package [^>]*branch-rate=\"0\.0\"' '$WORK_DIR/cobertura.xml'"
assert_true "the package holding the branch data reports its real branch rate" \
  "grep -q '<package name=\"lib\" line-rate=\"0.7500\" branch-rate=\"0.5000\"' '$WORK_DIR/cobertura.xml'"
# The GitLab templates scrape this exact spelling with a `coverage:` regex.
assert_true "the coverage line matches the GitLab 'coverage:' regex" \
  "grep -qE 'COVERAGE_PERCENT=[0-9.]+%' <<< \"\$COV_OUT\""

STATUS=0
DART_COVERAGE_MINIMUM=90 python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov.info" "$WORK_DIR/c2.xml" . > /dev/null 2>&1 || STATUS=$?
assert_true "DART_COVERAGE_MINIMUM fails the job below the threshold" "[[ $STATUS -eq 1 ]]"

STATUS=0
DART_COVERAGE_MINIMUM=80 python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov.info" "$WORK_DIR/c3.xml" . > /dev/null 2>&1 || STATUS=$?
assert_true "DART_COVERAGE_MINIMUM passes at or above the threshold" "[[ $STATUS -eq 0 ]]"

# Generated Dart is near-universal (`build_runner`, `freezed`, `json_serializable`)
# and a generator emitting one literal per line moves the total by tens of points
# while saying nothing about whether anything is tested. The fixture reproduces
# exactly that shape: a hand-written library at 75%, buried by a 16-line
# catalogue and a `freezed` union that no test will ever execute.
cat > "$WORK_DIR/lcov-generated.info" <<'EOF'
SF:lib/app.dart
DA:1,1
DA:2,1
DA:3,1
DA:4,0
end_of_record
SF:lib/presentation/i18n/catalog.g.dart
DA:1,0
DA:2,0
DA:3,0
DA:4,0
DA:5,0
DA:6,0
DA:7,0
DA:8,0
DA:9,0
DA:10,0
DA:11,0
DA:12,0
DA:13,0
DA:14,0
DA:15,0
DA:16,0
end_of_record
SF:lib/domain/user.freezed.dart
DA:1,0
DA:2,0
end_of_record
EOF

GEN_OUT="$(python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov-generated.info" "$WORK_DIR/gen1.xml" . 2>&1)"
assert_true "generated sources drag the unexcluded total down (3/22)" \
  "grep -q 'COVERAGE_PERCENT=13.64%' <<< \"\$GEN_OUT\""

# `fnmatch`'s `*` crosses `/`, unlike a shell glob, which is what keeps the
# useful pattern short: no `**/` prefix and no per-directory pattern.
GEN_OUT="$(DART_COVERAGE_EXCLUDE='*.g.dart *.freezed.dart' \
  python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov-generated.info" "$WORK_DIR/gen2.xml" . 2>&1)"
assert_true "DART_COVERAGE_EXCLUDE drops generated sources from the percentage" \
  "grep -q 'COVERAGE_PERCENT=75.00%' <<< \"\$GEN_OUT\""
assert_true "a bare '*.g.dart' matches at any depth (fnmatch, not a shell glob)" \
  "grep -q 'excluded: lib/presentation/i18n/catalog.g.dart' <<< \"\$GEN_OUT\""
# The gate and the report must agree on what was measured: a document that still
# lists a file the percentage no longer counts sends whoever opens it looking for
# the discrepancy.
assert_true "an excluded file is dropped from the Cobertura document too" \
  "! grep -q 'catalog.g.dart' '$WORK_DIR/gen2.xml'"
assert_true "a file that matches no pattern survives the exclusion" \
  "grep -q 'app.dart' '$WORK_DIR/gen2.xml'"
# The count is what makes an over-broad pattern visible; without it a `*` that
# excluded the whole project would report 0/0 and pass every threshold silently.
assert_true "the number of excluded files is printed" \
  "grep -q 'COVERAGE_EXCLUDED=2 of 3 file(s) dropped' <<< \"\$GEN_OUT\""
assert_true "the exclusion line is printed BEFORE the coverage line GitLab scrapes" \
  "[[ \$(grep -n 'COVERAGE_EXCLUDED=' <<< \"\$GEN_OUT\" | cut -d: -f1) -lt \$(grep -n 'COVERAGE_PERCENT=' <<< \"\$GEN_OUT\" | cut -d: -f1) ]]"
assert_true "the coverage line still matches the GitLab 'coverage:' regex" \
  "grep -qE 'COVERAGE_PERCENT=[0-9.]+%' <<< \"\$GEN_OUT\""

# A GitHub Actions input and an Azure DevOps variable are single strings a caller
# naturally comma-separates; a GitLab `variables:` entry is as naturally written
# space-separated. Reading only one spelling turns the other into a single
# pattern that matches nothing, and nothing would say so.
GEN_OUT="$(DART_COVERAGE_EXCLUDE='*.g.dart,*.freezed.dart' \
  python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov-generated.info" "$WORK_DIR/gen3.xml" . 2>&1)"
assert_true "comma-separated patterns behave identically to space-separated ones" \
  "grep -q 'COVERAGE_PERCENT=75.00%' <<< \"\$GEN_OUT\""

# A typo'd pattern must announce itself as `0 of N` rather than look like success.
GEN_OUT="$(DART_COVERAGE_EXCLUDE='*.generated.dart' \
  python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov-generated.info" "$WORK_DIR/gen4.xml" . 2>&1)"
assert_true "a pattern that matches nothing is reported as '0 of N', not silence" \
  "grep -q 'COVERAGE_EXCLUDED=0 of 3 file(s) dropped' <<< \"\$GEN_OUT\""

# The gate must see the SAME set the report does, or the two disagree by exactly
# the generated files -- which is the whole reason the variable exists.
STATUS=0
DART_COVERAGE_MINIMUM=70 python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov-generated.info" "$WORK_DIR/gen5.xml" . > /dev/null 2>&1 || STATUS=$?
assert_true "the gate fails on generated sources when nothing is excluded" "[[ $STATUS -eq 1 ]]"

STATUS=0
DART_COVERAGE_MINIMUM=70 DART_COVERAGE_EXCLUDE='*.g.dart *.freezed.dart' \
  python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov-generated.info" "$WORK_DIR/gen6.xml" . > /dev/null 2>&1 || STATUS=$?
assert_true "the gate is evaluated on the excluded set, not the raw one" "[[ $STATUS -eq 0 ]]"

# An unset variable must change nothing at all, for every existing consumer.
GEN_OUT="$(python3 "$DART_DIR/test/lcov_to_cobertura.py" \
  "$WORK_DIR/lcov.info" "$WORK_DIR/gen7.xml" . 2>&1)"
assert_true "an unset DART_COVERAGE_EXCLUDE prints no exclusion line at all" \
  "! grep -q 'COVERAGE_EXCLUDED' <<< \"\$GEN_OUT\""

# ---------------------------------------------------------------------------
echo ""
echo "--- 7b. LCOV to Markdown summary (the pull-request comment) ---"
# ---------------------------------------------------------------------------

# The JavaScript pipelines post a coverage table on every pull request; Dart
# emits LCOV only, so the runner renders its own from the SAME parse the
# converter above uses. Every assertion here is about agreement: the comment
# must show the number the gate evaluated, over the files the gate counted, or
# it sends the reader looking for a discrepancy that is only a second
# implementation.
MD="$DART_DIR/test/lcov_to_markdown.py"

assert_true "test/run.sh renders the Markdown summary beside the Cobertura report" \
  "grep -q 'lcov_to_markdown.py' '$DART_DIR/test/run.sh'"
assert_true "test/run.sh treats a summary it could not render as a warning, not a failure" \
  "grep -A2 'lcov_to_markdown.py' '$DART_DIR/test/run.sh' | grep -q 'WARNING: could not render the coverage summary'"

STATUS=0
DART_COVERAGE_MINIMUM=80 python3 "$MD" "$WORK_DIR/lcov.info" "$WORK_DIR/cov80.md" > /dev/null 2>&1 || STATUS=$?
assert_true "markdown: the summary is written and the script exits 0" \
  "[[ $STATUS -eq 0 && -s '$WORK_DIR/cov80.md' ]]"
assert_true "markdown: the Lines row carries the converter's percentage and counts" \
  "grep -q '| Lines | 83.33% (🎯 80%) | 5 / 6 |' '$WORK_DIR/cov80.md'"
assert_true "markdown: a total at or above the floor is marked green" \
  "grep -q '| 🟢 | Lines |' '$WORK_DIR/cov80.md'"
assert_true "markdown: branch coverage is a row of its own when BRDA rows exist" \
  "grep -q '| Branches | 50.00% | 1 / 2 |' '$WORK_DIR/cov80.md'"
assert_true "markdown: the branch row carries no threshold marker (the gate is lines only)" \
  "! grep -q '| Branches | 50.00% (' '$WORK_DIR/cov80.md'"

# A report, not a gate: the converter already fails the job below the floor,
# and a second exit code for the same fact would report one shortfall twice.
STATUS=0
DART_COVERAGE_MINIMUM=90 python3 "$MD" "$WORK_DIR/lcov.info" "$WORK_DIR/cov90.md" > /dev/null 2>&1 || STATUS=$?
assert_true "markdown: a total below the floor is marked red" \
  "grep -q '| 🔴 | Lines | 83.33% (🎯 90%) |' '$WORK_DIR/cov90.md'"
assert_true "markdown: a total below the floor still exits 0 (the converter holds the gate)" \
  "[[ $STATUS -eq 0 ]]"

python3 "$MD" "$WORK_DIR/lcov.info" "$WORK_DIR/covnone.md" > /dev/null 2>&1
assert_true "markdown: with no floor the row is blue and carries no target" \
  "grep -q '| 🔵 | Lines | 83.33% | 5 / 6 |' '$WORK_DIR/covnone.md'"

# The exclusions the gate applies must be the exclusions the comment shows.
DART_COVERAGE_EXCLUDE='*.g.dart *.freezed.dart' python3 "$MD" \
  "$WORK_DIR/lcov-generated.info" "$WORK_DIR/covgen.md" > /dev/null 2>&1
assert_true "markdown: DART_COVERAGE_EXCLUDE drops generated sources from the total" \
  "grep -q '| Lines | 75.00% | 3 / 4 |' '$WORK_DIR/covgen.md'"
assert_true "markdown: the exclusion is stated with its count and its patterns" \
  "grep -q '2 file(s) excluded by \`DART_COVERAGE_EXCLUDE\` (\`\*.g.dart \*.freezed.dart\`)' '$WORK_DIR/covgen.md'"
assert_true "markdown: a tracefile with no BRDA rows has no branch row and says why" \
  "! grep -q '| Branches |' '$WORK_DIR/covgen.md' && grep -q 'Branch coverage is not in the tracefile' '$WORK_DIR/covgen.md'"
assert_true "markdown: a push build (no diff base) carries no file section" \
  "! grep -q '<details>' '$WORK_DIR/covgen.md'"

# The file section is what a reviewer reads: the coverage of what is being
# merged. It is built from a diff of two TREES rather than a history, because a
# CI checkout is shallow, and from repository paths mapped back onto the
# package's, because the two differ in a monorepo -- which the fixture is.
#
# No global git configuration reaches these commits: a `commit.gpgsign = true`
# in the developer's own config, with a signer that needs an unlocked agent,
# would otherwise fail the fixture rather than the code under test.
MD_REPO="$WORK_DIR/md-repo"
md_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$MD_REPO" -c user.email='test@example.com' -c user.name='test' \
    -c commit.gpgsign=false "$@"
}
rm -rf "$MD_REPO"
mkdir -p "$MD_REPO/app/lib/src" "$MD_REPO/app/test"
md_git init --quiet
printf 'int answer() => 41;\n' > "$MD_REPO/app/lib/main.dart"
printf 'int util() => 1;\n' > "$MD_REPO/app/lib/src/util.dart"
printf '// covers answer()\n' > "$MD_REPO/app/test/main_test.dart"
printf 'base\n' > "$MD_REPO/README.md"
md_git add -A
md_git commit --quiet -m 'base'
MD_BASE="$(md_git rev-parse HEAD)"
printf 'int answer() => 42;\n' > "$MD_REPO/app/lib/main.dart"
printf '// covers answer() and util()\n' > "$MD_REPO/app/test/main_test.dart"
printf 'changed\n' > "$MD_REPO/README.md"
md_git add -A
md_git commit --quiet -m 'change'
cp "$WORK_DIR/lcov.info" "$MD_REPO/app/lcov.info"

STATUS=0
(cd "$MD_REPO/app" && DART_COVERAGE_MINIMUM=80 DART_COVERAGE_DIFF_BASE="$MD_BASE" \
  python3 "$MD" lcov.info changed.md > /dev/null 2>&1) || STATUS=$?
assert_true "markdown: a diff base adds a collapsed file section" \
  "[[ $STATUS -eq 0 ]] && grep -q '<details>' '$MD_REPO/app/changed.md'"
assert_true "markdown: a changed, instrumented file is listed with its own coverage and uncovered lines" \
  "grep -q '| \`lib/main.dart\` | 🔴 | 75.00% | 3 / 4 | 4 |' '$MD_REPO/app/changed.md'"
assert_true "markdown: an instrumented file the change did not touch is not listed" \
  "! grep -q 'util.dart' '$MD_REPO/app/changed.md'"
assert_true "markdown: a repository path is mapped onto the package's (the 'app/' prefix is stripped)" \
  "! grep -q 'app/lib/main.dart' '$MD_REPO/app/changed.md'"
assert_true "markdown: a changed file outside the tracefile is counted, and one outside the package is not" \
  "grep -q '^1 other changed file(s) are not in the tracefile' '$MD_REPO/app/changed.md'"
assert_true "markdown: the summary counts the instrumented files against all the changed ones" \
  "grep -q 'File coverage &mdash; 1 of 2 changed file(s) since' '$MD_REPO/app/changed.md'"

# A change that touches no instrumented source -- a docs or test-only pull
# request -- must say so, not "0 changed file(s)" over "N more ... are not in
# the tracefile", as if N were listed above.
printf '// covers answer() and util(), twice\n' > "$MD_REPO/app/test/main_test.dart"
# Only the test file: `add -A` would sweep the renderer's own outputs above into
# this commit and the diff would count them as the change under test.
md_git add app/test/main_test.dart
md_git commit --quiet -m 'tests only'
MD_TESTS_ONLY_BASE="$(md_git rev-parse HEAD~1)"
(cd "$MD_REPO/app" && DART_COVERAGE_DIFF_BASE="$MD_TESTS_ONLY_BASE" \
  python3 "$MD" lcov.info testsonly.md > /dev/null 2>&1)
assert_true "markdown: a change with no instrumented file says so in the summary" \
  "grep -q 'File coverage &mdash; none of the 1 changed file(s) since' '$MD_REPO/app/testsonly.md'"
assert_true "markdown: ...and explains it without claiming anything was listed" \
  "grep -q '^Nothing to list: tests, assets' '$MD_REPO/app/testsonly.md' && ! grep -q 'other changed file' '$MD_REPO/app/testsonly.md'"
(cd "$MD_REPO/app" && DART_COVERAGE_DIFF_BASE="$(md_git rev-parse HEAD)" \
  python3 "$MD" lcov.info nochange.md > /dev/null 2>&1)
assert_true "markdown: a base equal to HEAD reads as no file changed" \
  "grep -q 'File coverage &mdash; no file changed since' '$MD_REPO/app/nochange.md'"

# Listing the files is the one step that can fail for reasons that have nothing
# to do with the code -- no network for the fetch, a base the checkout never
# saw -- and none of them is a reason to fail a green suite.
STATUS=0
(cd "$MD_REPO/app" && DART_COVERAGE_DIFF_BASE=0123456789012345678901234567890123456789 \
  python3 "$MD" lcov.info nobase.md > "$WORK_DIR/nobase.log" 2>&1) || STATUS=$?
assert_true "markdown: an unresolvable diff base exits 0 and still writes the totals" \
  "[[ $STATUS -eq 0 ]] && grep -q '| Lines | 83.33% |' '$MD_REPO/app/nobase.md'"
assert_true "markdown: the missing file section says why instead of appearing empty" \
  "grep -q 'is unavailable: fatal: bad object' '$MD_REPO/app/nobase.md'"
assert_true "markdown: the cause is also printed as a warning for the job log" \
  "grep -q 'WARNING: could not list the files changed since' '$WORK_DIR/nobase.log'"

# Uncovered lines are folded into ranges; a column of every number would be the
# file again.
cat > "$MD_REPO/app/ranges.info" <<'EOF'
SF:lib/main.dart
DA:10,0
DA:11,0
DA:12,0
DA:13,1
DA:20,0
DA:30,0
DA:31,0
end_of_record
EOF
(cd "$MD_REPO/app" && DART_COVERAGE_DIFF_BASE="$MD_BASE" \
  python3 "$MD" ranges.info ranges.md > /dev/null 2>&1)
assert_true "markdown: consecutive uncovered lines are folded into ranges" \
  "grep -q '| 1 / 7 | 10-12, 20, 30-31 |' '$MD_REPO/app/ranges.md'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 7c. Test event stream filter (the GitHub Test Results check) ---"
# ---------------------------------------------------------------------------

# `flutter test --machine` shares stdout with pub's progress lines and with
# flutter_tools' own array-shaped events, and the Dart parser behind the GitHub
# `Test Results` check fails the whole report on the first line it cannot
# parse. `tojunit` tolerates the noise, which is why the JUnit report never
# showed it. The fixture is the shape one real run produced.
FILTER="$DART_DIR/test/filter_test_events.py"
cat > "$WORK_DIR/events.raw" <<'EOF'
Resolving dependencies...
Got dependencies!
[{"event":"test.startedProcess","params":{"vmServiceUri":"http://127.0.0.1:1/"}}]
{"protocolVersion":"0.1.1","runnerVersion":"1.25.0","pid":1,"type":"start","time":0}
{"suite":{"id":0,"platform":"vm","path":"/w/test/sample_test.dart"},"type":"suite","time":1}

{"test":{"id":1,"name":"adds","suiteID":0,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":3,"column":3,"url":"file:///w/test/sample_test.dart"},"type":"testStart","time":2}
{"testID":1,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":3}
{"success":true,"type":"done","time":4}
EOF
STATUS=0
FILTER_OUT="$(python3 "$FILTER" "$WORK_DIR/events.raw" "$WORK_DIR/test-results.json" 2>&1)" || STATUS=$?
assert_true "events: the filter exits 0 and writes the filtered stream" \
  "[[ $STATUS -eq 0 && -s '$WORK_DIR/test-results.json' ]]"
assert_equals "events: pub's progress lines, the array event and the blank line are dropped" \
  "5" "$(wc -l < "$WORK_DIR/test-results.json" | tr -d ' ')"
assert_true "events: every kept line is a JSON object carrying a type" \
  "python3 -c \"import json; [json.loads(l)['type'] for l in open('$WORK_DIR/test-results.json')]\""
assert_true "events: kept lines are written verbatim" \
  "grep -qF '{\"suite\":{\"id\":0,\"platform\":\"vm\",\"path\":\"/w/test/sample_test.dart\"},\"type\":\"suite\",\"time\":1}' '$WORK_DIR/test-results.json'"
assert_true "events: what was kept and dropped is printed for the job log" \
  "grep -q 'TEST_EVENTS_KEPT=5 (dropped 3 non-event line(s))' <<< \"\$FILTER_OUT\""

# A stream that is all noise must leave NO output: the workflow's `hashFiles`
# guard is what turns "nothing to report" into a skipped step rather than an
# empty check, and a stale file from an earlier run must not be read as this
# run's suite.
printf 'Resolving dependencies...\n' > "$WORK_DIR/noise.raw"
cp "$WORK_DIR/test-results.json" "$WORK_DIR/stale.json"
STATUS=0
FILTER_OUT="$(python3 "$FILTER" "$WORK_DIR/noise.raw" "$WORK_DIR/stale.json" 2>&1)" || STATUS=$?
assert_true "events: a stream with no test event exits 0, warns, and removes a stale output" \
  "[[ $STATUS -eq 0 && ! -f '$WORK_DIR/stale.json' ]] && grep -q 'WARNING' <<< \"\$FILTER_OUT\""

assert_true "test/run.sh filters the event stream for the Test Results check" \
  "grep -q 'filter_test_events.py' '$DART_DIR/test/run.sh'"
assert_true "test/run.sh treats a stream it could not filter as a warning, not a failure" \
  "grep -A2 'filter_test_events.py' '$DART_DIR/test/run.sh' | grep -q 'WARNING: could not filter'"
# The raw stream's location is a contract the filter reads; a rename would make
# the check silently skip through `hashFiles` rather than fail.
assert_true "test/run.sh keeps the raw stream where the filter reads it" \
  "grep -q 'EVENTS_FILE=\"\$DART_TOOL_REPORT_PATH/test-events.json\"' '$DART_DIR/test/run.sh'"
assert_true "test/run.sh writes the filtered stream as build/reports/test-results.json" \
  "grep -q 'TEST_RESULTS_FILE=\"\$REPORT_ROOT/test-results.json\"' '$DART_DIR/test/run.sh'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 8. dart analyze machine-format parsing and severity gate ---"
# ---------------------------------------------------------------------------

# The fourth row carries an ESCAPED PIPE inside its message. A naive split on
# `|` yields nine fields, shifts every column, and files the finding against the
# wrong source location -- which is why this row exists.
cat > "$WORK_DIR/machine.txt" <<'EOF'
INFO|LINT|AVOID_PRINT|lib/main.dart|28|3|5|Don't invoke 'print' in production code.
WARNING|STATIC_WARNING|UNUSED_LOCAL_VARIABLE|lib/src/util.dart|12|9|3|The value of the local variable 'foo' isn't used.
ERROR|COMPILE_TIME_ERROR|UNDEFINED_METHOD|lib/src/api.dart|44|10|7|The method 'fetchz' isn't defined for the type 'Api'.
INFO|LINT|PREFER_CONST|lib/widgets/card.dart|7|5|9|Use 'a \| b' instead of a pipe here.
Analyzing project...
EOF

# Run from inside $WORK_DIR: the helper confines its report directory to the working
# directory, so the argument is a path relative to it rather than an absolute one.
STATUS=0
(cd "$WORK_DIR" && python3 "$DART_DIR/analyze/dart_analyze_report.py" "an" < "machine.txt") > /dev/null 2>&1 || STATUS=$?
assert_true "the default gate fails on an ERROR" "[[ $STATUS -eq 1 ]]"
assert_true "the JUnit report is well-formed XML" \
  "python3 -c \"import xml.dom.minidom as m; m.parse('$WORK_DIR/an/junit-analyze.xml')\""
assert_true "the JSON report is valid JSON" \
  "python3 -c \"import json; json.load(open('$WORK_DIR/an/analyze.json'))\""
assert_equals "all four diagnostics are parsed (the progress line is ignored)" \
  "4" "$(python3 -c "import json;print(json.load(open('$WORK_DIR/an/analyze.json'))['summary']['total'])")"
assert_equals "an escaped pipe inside a message is unescaped, not treated as a separator" \
  "Use 'a | b' instead of a pipe here." \
  "$(python3 -c "import json;print(json.load(open('$WORK_DIR/an/analyze.json'))['diagnostics'][3]['message'])")"
assert_equals "the row with the escaped pipe keeps its correct file" \
  "lib/widgets/card.dart" \
  "$(python3 -c "import json;print(json.load(open('$WORK_DIR/an/analyze.json'))['diagnostics'][3]['file'])")"
# Fatal findings become failures; non-fatal ones stay visible as skipped rather
# than being dropped from the report entirely.
assert_true "fatal findings are recorded as JUnit failures" \
  "grep -c '<failure' '$WORK_DIR/an/junit-analyze.xml' | grep -qx '2'"
assert_true "non-fatal findings stay visible as JUnit skips" \
  "grep -c '<skipped' '$WORK_DIR/an/junit-analyze.xml' | grep -qx '2'"

head -1 "$WORK_DIR/machine.txt" > "$WORK_DIR/infos.txt"
STATUS=0
(cd "$WORK_DIR" && python3 "$DART_DIR/analyze/dart_analyze_report.py" "an2" < "infos.txt") > /dev/null 2>&1 || STATUS=$?
assert_true "INFO findings alone do not fail by default" "[[ $STATUS -eq 0 ]]"

STATUS=0
(cd "$WORK_DIR" && DART_FATAL_INFOS=true python3 "$DART_DIR/analyze/dart_analyze_report.py" "an3" \
  < "infos.txt") > /dev/null 2>&1 || STATUS=$?
assert_true "DART_FATAL_INFOS=true makes INFO findings fatal" "[[ $STATUS -eq 1 ]]"

STATUS=0
(cd "$WORK_DIR" && python3 "$DART_DIR/analyze/dart_analyze_report.py" "an4" < /dev/null) > /dev/null 2>&1 || STATUS=$?
assert_true "a clean analysis passes and still writes a valid JUnit report" \
  "[[ $STATUS -eq 0 ]] && python3 -c \"import xml.dom.minidom as m; m.parse('$WORK_DIR/an4/junit-analyze.xml')\""

# ---------------------------------------------------------------------------
echo ""
echo "--- 9. Tool gap: CodeQL is absent, Semgrep is substituted ---"
# ---------------------------------------------------------------------------

DART_RULES="$SCRIPTS_DIR/global/scripts/tools/semgrep/rules/dart.yaml"

# CodeQL has NO Dart extractor. A `codeql` job in a Dart template could only
# fail, so its absence is the correct state and this case defends it against a
# future "make the languages consistent" edit.
for template in \
  "$SCRIPTS_DIR/gitlab/dart/stages/20-security/dart.yaml" \
  "$SCRIPTS_DIR/azure-devops/dart/stages/20-security/dart.yaml"; do
  assert_true "$(basename "$(dirname "$(dirname "$(dirname "$template")")")"): no CodeQL job is wired for Dart" \
    "! grep -E '^[^#]*codeql' '$template'"
done
assert_true "GitHub: no CodeQL job is wired in the Dart workflow" \
  "! grep -E '^[^#]*20-security/codeql' '$SCRIPTS_DIR/.github/workflows/dart.yaml'"
assert_true "dart.mk leaves CODEQL_LANGUAGE unset so 'make sast' skips CodeQL" \
  "! grep -qE '^CODEQL_LANGUAGE' '$SCRIPTS_DIR/makefiles/dart.mk'"
# The skip has to be a real skip. Before the guard in common.mk, an unset
# language reached the run script and produced a bare usage error on every
# `make sast`.
assert_true "common.mk skips CodeQL cleanly when no language is configured" \
  "grep -q 'skipping CodeQL' '$SCRIPTS_DIR/makefiles/common.mk'"
# The guard must be a RECIPE-level test. A make-level `ifeq` is evaluated while
# common.mk is parsed -- before any language fragment has set the variable -- so
# it would disable CodeQL for every language, not just Dart.
assert_true "the CodeQL guard is evaluated at recipe time, not at parse time" \
  "! grep -qE '^ifeq.*CODEQL_LANGUAGE' '$SCRIPTS_DIR/makefiles/common.mk'"

# The Semgrep Registry publishes no Dart rules at all (`p/dart` is a 404 and
# `r/dart` returns an empty `rules: []`), so this repository ships its own. If
# the file disappears, a Dart scan silently degrades to language-agnostic packs
# while still reporting success.
assert_true "a first-party Dart Semgrep ruleset is shipped" "[[ -f '$DART_RULES' ]]"
assert_true "the Dart ruleset is valid YAML" \
  "python3 -c \"import yaml,sys; yaml.safe_load(open('$DART_RULES'))\""
assert_true "the Dart ruleset declares rules for the 'dart' language" \
  "python3 -c \"
import yaml
rules = yaml.safe_load(open('$DART_RULES'))['rules']
assert rules, 'no rules'
assert all('dart' in r['languages'] for r in rules), 'a rule does not target dart'
\""
# The TLS-bypass rule is the one that must never be dropped: an unconditional
# `badCertificateCallback` returning true is the single most common critical
# defect in Flutter networking code.
assert_true "the ruleset covers the TLS-verification bypass" \
  "grep -q 'dart-tls-verification-disabled' '$DART_RULES'"
assert_true "the shared Semgrep runner loads a repo-shipped ruleset by language" \
  "grep -q 'tools/semgrep/rules/\$SEMGREP_LANGUAGE.yaml' '$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh'"
# Passing an unpublished pack is FATAL to semgrep, taking the language-agnostic
# packs down with it -- so the runner has to probe rather than assume.
assert_true "the shared Semgrep runner skips an unpublished registry pack" \
  "grep -q 'semgrep_registry_pack_exists' '$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh'"
# The language pack must be added CONDITIONALLY (via the positional-parameter
# list, after the registry probe) and never as a fixed line of the `semgrep`
# invocation. An unconditional `--config p/<lang>` is what made an unpublished
# pack fatal to the whole scan in the first place, so this checks placement
# rather than mere presence.
assert_true "the language pack is added conditionally, not hardcoded into the semgrep invocation" \
  "! grep -qE '^[[:space:]]+--config \"p/\\\$SEMGREP_LANGUAGE\" \\\\\\\\\$' '$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh'"
assert_equals "the language pack is referenced exactly once, on the conditional 'set --' line" \
  "1" \
  "$(grep -c 'set -- "\$@" --config "p/\$SEMGREP_LANGUAGE"' "$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh")"

if command -v semgrep > /dev/null 2>&1; then
  assert_true "the Dart ruleset passes 'semgrep --validate'" \
    "semgrep --metrics=off --disable-version-check --validate --config '$DART_RULES' 2>&1 | grep -q 'Configuration is valid'"

  # Matching is asserted against real Dart, not against the rule text: Semgrep's
  # Dart support is experimental, and several intuitive pattern spellings load
  # cleanly and then match nothing (the `"...$..."` string-ellipsis idiom in
  # particular). A rule that silently matches nothing is worse than no rule.
  mkdir -p "$WORK_DIR/dartsrc"
  cat > "$WORK_DIR/dartsrc/vuln.dart" <<'EOF'
import 'dart:io';
import 'dart:math';

void insecure(HttpClient client) {
  client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
}

Future<void> net() async {
  await Uri.parse("http://api.example.com/v1/items");
  await Uri.parse("http://localhost:8080/health");
  await Uri.parse("https://api.example.com/v1/items");
}

void weak() {
  var sessionToken = Random();
  var particleOffset = Random();
  print(sessionToken.hashCode + particleOffset.hashCode);
}

Future<void> shell(String name) async {
  await Process.run("ls $name", [], runInShell: true);
  await Process.run("ls", [name]);
}

Future<void> query(dynamic db, String user) async {
  await db.rawQuery("SELECT * FROM users WHERE name = '$user'");
  await db.rawQuery("SELECT * FROM users WHERE name = ?", [user]);
}

Future<void> store(dynamic prefs, String v) async {
  await prefs.setString("auth_token", v);
  await prefs.setString("theme_mode", v);
}

void web(dynamic controller) {
  controller.javascriptMode = JavascriptMode.unrestricted;
  controller.settings.allowFileAccessFromFileURLs = true;
}
EOF
  SEMGREP_JSON="$(semgrep --metrics=off --disable-version-check --no-git-ignore \
    --config "$DART_RULES" --json "$WORK_DIR/dartsrc" 2>/dev/null)"
  FIRED="$(python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
print(len({r['check_id'].split('.')[-1] for r in d['results']}))
" <<< "$SEMGREP_JSON")"
  TOTAL_RULES="$(python3 -c "import yaml;print(len(yaml.safe_load(open('$DART_RULES'))['rules']))")"
  assert_equals "every shipped Dart rule matches its vulnerable sample" "$TOTAL_RULES" "$FIRED"

  # The safe counterparts sit on known lines; a rule firing on them would make
  # the ruleset noise a team disables rather than a gate it trusts.
  HITS="$(python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
print(' '.join(sorted(str(r['start']['line']) for r in d['results'])))
" <<< "$SEMGREP_JSON")"
  assert_true "the parameterised SQL query is not flagged" "! grep -qw '27' <<< '$HITS'"
  assert_true "the non-shell Process.run is not flagged" "! grep -qw '22' <<< '$HITS'"
  assert_true "the https:// URL is not flagged" "! grep -qw '11' <<< '$HITS'"
  assert_true "the loopback http:// URL is not flagged" "! grep -qw '10' <<< '$HITS'"
  assert_true "a non-security-named Random() is not flagged" "! grep -qw '16' <<< '$HITS'"
  assert_true "a non-sensitive SharedPreferences key is not flagged" "! grep -qw '33' <<< '$HITS'"
else
  skip "semgrep is not installed; rule validation and matching assertions skipped"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 10. Cross-platform wiring ---"
# ---------------------------------------------------------------------------

# A stage added to one platform and forgotten on the other two leaves three
# files that are each valid YAML on their own, so nothing else in CI catches it.
for stage in 10-code-check 20-security 30-tests 35-management; do
  assert_true "GitLab: the $stage stage exists" \
    "[[ -f '$SCRIPTS_DIR/gitlab/dart/stages/$stage/dart.yaml' ]]"
  assert_true "Azure DevOps: the $stage stage exists" \
    "[[ -f '$SCRIPTS_DIR/azure-devops/dart/stages/$stage/dart.yaml' ]]"
done

for entry in dart-docker dart-library flutter-docker flutter-artifacts; do
  assert_true "GitLab: the $entry entry template exists" \
    "[[ -f '$SCRIPTS_DIR/gitlab/dart/$entry.yaml' ]]"
  assert_true "Azure DevOps: the $entry entry template exists" \
    "[[ -f '$SCRIPTS_DIR/azure-devops/dart/$entry.yaml' ]]"
done

for workflow in dart dart-docker dart-library flutter-artifacts; do
  assert_true "GitHub: the $workflow workflow exists" \
    "[[ -f '$SCRIPTS_DIR/.github/workflows/$workflow.yaml' ]]"
done

# `runs-on` is a HARD selector: GitHub matches it against the runner labels and
# never substitutes, so a job that hardcodes `ubuntu-latest` is rejected before it
# starts once an account's hosted minutes run out -- while a registered
# self-hosted runner sits idle, because nothing asked for it. A reusable workflow
# also validates its callers against its declared input list, so a consumer
# cannot work around the omission from outside; the only recourse is abandoning
# the workflow and re-declaring every job locally.
#
# Asserted on the PARSED document rather than by grep: YAML 1.1 reads the `on:`
# key as the boolean `true`, so the input list is not where a reader expects it,
# and a grep for the name would equally pass on a file that only mentions it in a
# comment.
for workflow in dart dart-docker dart-library flutter-artifacts; do
  assert_equals "GitHub: $workflow.yaml declares the runs_on input" \
    "yes" \
    "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/$workflow.yaml'))
trigger = d.get('on', d.get(True))
print('yes' if 'runs_on' in trigger['workflow_call']['inputs'] else 'no')
")"
  assert_equals "GitHub: $workflow.yaml pins no job to a hardcoded runner" \
    "" \
    "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/$workflow.yaml'))
print(' '.join(sorted(
    name for name, job in d['jobs'].items()
    if 'ubuntu-latest' in str(job.get('runs-on', ''))
)))
")"
done

# A child workflow that declares `runs_on` but forgets to FORWARD it moves its own
# delivery jobs onto the chosen runner while every quality job it calls through
# `dart.yaml` stays on the hosted one -- half a migration, and green either way,
# so nothing reports it.
for workflow in dart-docker dart-library flutter-artifacts; do
  assert_equals "GitHub: $workflow.yaml forwards runs_on into the dart job" \
    "yes" \
    "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/$workflow.yaml'))
print('yes' if 'runs_on' in d['jobs']['dart'].get('with', {}) else 'no')
")"
done

# The `30-tests/all` action declared `test_args` and `coverage_exclude` long
# before the reusable workflow exposed them, which made them unreachable: the
# workflow is the only entry point a GitHub consumer has. Assert the whole chain
# -- declared on `dart.yaml`, forwarded to the action, turned into the
# environment variable the runner and the converter actually read -- because a
# break at any one link leaves the other two looking correct.
for input in test_args coverage_exclude; do
  assert_equals "GitHub: dart.yaml declares the $input input" \
    "yes" \
    "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/dart.yaml'))
trigger = d.get('on', d.get(True))
print('yes' if '$input' in trigger['workflow_call']['inputs'] else 'no')
")"
  assert_equals "GitHub: dart.yaml forwards $input to the 30-tests/all action" \
    "yes" \
    "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/dart.yaml'))
step = d['jobs']['tests-test_all']['steps'][0]
print('yes' if '$input' in step.get('with', {}) else 'no')
")"
done

for pair in 'test_args:DART_TEST_ARGS' 'coverage_exclude:DART_COVERAGE_EXCLUDE' \
            'coverage_diff_base:DART_COVERAGE_DIFF_BASE'; do
  assert_equals "GitHub: the 30-tests/all action maps ${pair%%:*} onto ${pair##*:}" \
    "yes" \
    "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/github/dart/stages/30-tests/all/action.yaml'))
steps = [s for s in d['runs']['steps'] if '${pair##*:}' in s.get('env', {})]
print('yes' if steps and 'inputs.${pair%%:*}' in steps[0]['env']['${pair##*:}'] else 'no')
")"
done


# The pull request's base reaches the renderer the same way, but from the EVENT
# rather than from a consumer input: `github.event.pull_request.base.sha` on a
# pull request, empty on a push, and nothing a caller could usefully override.
assert_equals "GitHub: dart.yaml hands the pull request's base SHA to the 30-tests/all action" \
  "yes" \
  "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/dart.yaml'))
step = d['jobs']['tests-test_all']['steps'][0]
print('yes' if 'github.event.pull_request.base.sha' in str(step.get('with', {}).get('coverage_diff_base', '')) else 'no')
")"

# The comment is the parity the JavaScript pipelines already have, and every
# clause of the step is load-bearing: `always()` reports on a red suite, which
# is when the number matters most; the event guard keeps a push from trying to
# comment on a pull request that does not exist; the `hashFiles` guard keeps a
# project whose suite produced no tracefile from failing on a missing file
# rather than on the cause; and `continue-on-error` keeps a refused post -- a
# caller that granted no `pull-requests: write`, or a pull request from a fork,
# whose token is read-only whatever the caller grants -- a yellow step rather
# than a red test job, which is what makes the change additive for every
# existing consumer. The posting is a THIRD-PARTY action, so it is pinned like
# every other one -- test-supply-chain.sh holds that edge.
assert_equals "GitHub: tests-test_all posts the coverage summary as a sticky pull-request comment" \
  "yes" \
  "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/dart.yaml'))
steps = [s for s in d['jobs']['tests-test_all']['steps']
         if s.get('uses', '').startswith('marocchino/sticky-pull-request-comment@')]
ok = (len(steps) == 1
      and steps[0]['with'].get('path') == 'build/reports/coverage.md'
      and 'always()' in steps[0].get('if', '')
      and \"github.event_name == 'pull_request'\" in steps[0].get('if', '')
      and \"hashFiles('build/reports/coverage.md')\" in steps[0].get('if', ''))
print('yes' if ok else 'no')
")"
assert_equals "GitHub: a refused comment (no grant, or a fork's read-only token) never fails tests-test_all" \
  "yes" \
  "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/dart.yaml'))
steps = [s for s in d['jobs']['tests-test_all']['steps']
         if s.get('uses', '').startswith('marocchino/sticky-pull-request-comment@')]
print('yes' if steps and steps[0].get('continue-on-error') is True else 'no')
")"
assert_equals "GitHub: tests-test_all writes the same summary to the job summary of every run" \
  "yes" \
  "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/dart.yaml'))
steps = [s for s in d['jobs']['tests-test_all']['steps']
         if 'GITHUB_STEP_SUMMARY' in s.get('run', '')]
ok = (len(steps) == 1
      and 'build/reports/coverage.md' in steps[0]['run']
      and 'always()' in steps[0].get('if', '')
      and \"hashFiles('build/reports/coverage.md')\" in steps[0].get('if', ''))
print('yes' if ok else 'no')
")"
# A consumer that grants no `pull-requests: write` sees the step fail by name.
# The footer is where every workflow here records what a caller must grant, so
# the requirement is asserted there rather than assumed.
assert_true "GitHub: dart.yaml's permissions note names pull-requests: write for the comment" \
  "grep -q \"^#   pull-requests: 'write' # tests-test_all\" '$SCRIPTS_DIR/.github/workflows/dart.yaml'"

# The Test Results check is the parity `go.yaml` and `yarn.yaml` have through the
# same action. `dart-json` over the FILTERED stream rather than `java-junit` over
# the JUnit, because `tojunit`'s class names are the runner's absolute path with
# the separators turned into dots; `always()` and the `hashFiles` guard as on
# the coverage steps; `continue-on-error` because a fork's token cannot create
# a check run whatever the caller grants.
assert_equals "GitHub: tests-test_all publishes the suite as a Test Results check from the filtered stream" \
  "yes" \
  "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/.github/workflows/dart.yaml'))
steps = [s for s in d['jobs']['tests-test_all']['steps']
         if s.get('uses', '').startswith('dorny/test-reporter@')]
ok = (len(steps) == 1
      and steps[0]['with'].get('reporter') == 'dart-json'
      and steps[0]['with'].get('path') == 'build/reports/test-results.json'
      and 'always()' in steps[0].get('if', '')
      and \"hashFiles('build/reports/test-results.json')\" in steps[0].get('if', '')
      and steps[0].get('continue-on-error') is True)
print('yes' if ok else 'no')
")"
assert_true "GitHub: dart.yaml's permissions note names checks: write for the Test Results check" \
  "grep -q \"^#   checks: 'write' # tests-test_all\" '$SCRIPTS_DIR/.github/workflows/dart.yaml'"

for action in 10-code-check/format 10-code-check/analyze 10-code-check/unused \
              20-security/osv-scanner 30-tests/all \
              40-delivery/build 40-delivery/publish; do
  assert_true "GitHub: the $action composite action exists" \
    "[[ -f '$SCRIPTS_DIR/github/dart/stages/$action/action.yaml' ]]"
done

# `upload-artifact` splits its `path` input on NEWLINES. A quoted multi-line YAML
# scalar folds into one space-separated line, so several patterns written that way
# arrive as a single glob containing spaces and match nothing -- and with
# `if-no-files-found: warn` the job still goes green, publishing an empty artifact.
# Assert on the PARSED value, since both spellings look identical in the source.
assert_equals "the build action's artifact path stays newline-separated (not YAML-folded)" \
  "4" \
  "$(python3 -c "
import yaml
d = yaml.safe_load(open('$SCRIPTS_DIR/github/dart/stages/40-delivery/build/action.yaml'))
path = [s for s in d['runs']['steps'] if s.get('uses', '').startswith('actions/upload-artifact')][0]['with']['path']
print(len([l for l in path.strip().splitlines() if l.strip()]))
")"

# Every `run.sh` path referenced by any Dart template must exist. A renamed
# script is otherwise discovered only when the job runs.
MISSING=""
while IFS= read -r referenced; do
  [[ -f "$SCRIPTS_DIR/$referenced" ]] || MISSING="$MISSING $referenced"
done < <(grep -rhoE 'global/scripts/languages/dart/[a-z-]+/run\.sh' \
  "$SCRIPTS_DIR/gitlab/dart" "$SCRIPTS_DIR/azure-devops/dart" \
  "$SCRIPTS_DIR/github/dart" "$SCRIPTS_DIR/makefiles/dart.mk" 2>/dev/null | sort -u)
assert_equals "every dart run.sh referenced by a template exists" "" "$MISSING"

# Each platform must reach every runner, or a stage silently does less there.
for runner in format analyze unused test sca build publish; do
  for platform in gitlab/dart azure-devops/dart github/dart; do
    assert_true "$platform references the $runner runner" \
      "grep -rq 'languages/dart/$runner/run.sh' '$SCRIPTS_DIR/$platform'"
  done
done

# No SBOM generator is asserted: pub has no native CycloneDX generator, so the
# BOM was produced by Trivy, which has been removed from this repository. The
# assertion below is the inverse -- nothing may reference the deleted runner.
for platform in gitlab/dart azure-devops/dart github/dart; do
  assert_true "$platform does NOT reference the removed cyclonedx runner" \
    "! grep -rq 'languages/dart/cyclonedx/run.sh' '$SCRIPTS_DIR/$platform'"
done

# ---------------------------------------------------------------------------
echo ""
echo "--- 11. Makefile fragment ---"
# ---------------------------------------------------------------------------

assert_true "makefiles/dart.mk exists" "[[ -f '$SCRIPTS_DIR/makefiles/dart.mk' ]]"
assert_true "dart.mk sets SEMGREP_LANGUAGE=dart" \
  "grep -qE '^SEMGREP_LANGUAGE \?= dart' '$SCRIPTS_DIR/makefiles/dart.mk'"

if command -v make > /dev/null 2>&1; then
  MK_PROJECT="$(make_project mkproj dart)"
  cat > "$MK_PROJECT/Makefile" <<EOF
SCRIPTS_DIR ?= $SCRIPTS_DIR
-include \$(SCRIPTS_DIR)/makefiles/common.mk
-include \$(SCRIPTS_DIR)/makefiles/dart.mk
EOF
  MK_OUT="$( (cd "$MK_PROJECT" && make -n sast 2>&1) || true )"
  assert_true "make sast skips CodeQL on a Dart project" \
    "grep -q 'skipping CodeQL' <<< \"\$MK_OUT\""
  assert_true "make sast runs Semgrep with the dart language" \
    "grep -q 'semgrep/run.sh \"dart\"' <<< \"\$MK_OUT\""
  assert_true "make sast includes the Dart-native SCA" \
    "grep -q 'languages/dart/sca/run.sh' <<< \"\$MK_OUT\""
  # Redefining a target that already has a recipe emits "overriding recipe for
  # target"; appending to a prerequisite-only rule (which is what `sast` is)
  # does not. This case keeps the fragment on the quiet side of that line.
  assert_true "including dart.mk after common.mk emits no make warning" \
    "! grep -qi 'overriding recipe' <<< \"\$MK_OUT\""

  # The same guard must NOT disable CodeQL for languages that do support it.
  cat > "$MK_PROJECT/Makefile.py" <<EOF
SCRIPTS_DIR ?= $SCRIPTS_DIR
-include \$(SCRIPTS_DIR)/makefiles/common.mk
-include \$(SCRIPTS_DIR)/makefiles/python.mk
EOF
  PY_OUT="$( (cd "$MK_PROJECT" && make -f Makefile.py -n codeql 2>&1) || true )"
  assert_true "a Python project still runs CodeQL (the guard is language-scoped)" \
    "grep -q 'codeql/run.sh \"python\"' <<< \"\$PY_OUT\""
else
  skip "make is not installed; Makefile fragment assertions skipped"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 12. YAML validity of every Dart template ---"
# ---------------------------------------------------------------------------

YAML_ERRORS="$(python3 - <<PY
import glob, yaml

class L(yaml.SafeLoader):
    pass

def ctor(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)

L.add_multi_constructor('!', ctor)

paths = sorted(set(
    glob.glob('$SCRIPTS_DIR/gitlab/dart/**/*.yaml', recursive=True)
    + glob.glob('$SCRIPTS_DIR/azure-devops/dart/**/*.yaml', recursive=True)
    + glob.glob('$SCRIPTS_DIR/github/dart/**/*.yaml', recursive=True)
    + glob.glob('$SCRIPTS_DIR/.github/workflows/dart*.yaml')
    + glob.glob('$SCRIPTS_DIR/.github/workflows/flutter*.yaml')
    + glob.glob('$SCRIPTS_DIR/global/scripts/tools/semgrep/rules/*.yaml')
    + glob.glob('$SCRIPTS_DIR/.docs/examples/github-flutter-artifacts/**/*.yaml', recursive=True)
    + glob.glob('$SCRIPTS_DIR/.docs/examples/gitlab-dart-library/*.yml')
))
bad = []
for p in paths:
    try:
        yaml.load(open(p), Loader=L)
    except Exception as exc:
        bad.append(p)
print(' '.join(bad))
PY
)"
assert_equals "every Dart template and example is valid YAML" "" "$YAML_ERRORS"

# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo -e "Passed:  ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:  ${RED}$TESTS_FAILED${NC}"
[[ $TESTS_SKIPPED -gt 0 ]] && echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}Dart pipeline validation FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}Dart pipeline validation passed${NC}"
exit 0
