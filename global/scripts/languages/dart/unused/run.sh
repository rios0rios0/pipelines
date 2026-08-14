#!/usr/bin/env sh
set -e

# Dead-code detection for Dart, the counterpart of `vulture` (Python), `knip`
# (JavaScript), `debride` (Ruby) and golangci-lint's `unused` (Go).
#
# `dart analyze` already reports unused imports, locals, fields and private
# elements, so this job exists for the two things the analyzer structurally
# cannot see: a PUBLIC declaration that nothing in the package references, and a
# `.dart` FILE that nothing imports. Both are invisible to a per-library
# analyzer because, from its point of view, a public API may have callers it
# cannot see -- only a whole-package pass can conclude otherwise.
#
# The tool is `dart_code_linter`, the maintained community fork of Dart Code
# Metrics. The original went commercial (DCM) and its last open-source release
# no longer supports current SDKs; the fork is Apache-2.0, actively released,
# and keeps the same `check-unused-code` / `check-unused-files` commands.
#
# Findings are advisory by default. Whole-package reachability analysis has a
# false-positive tail that the analyzer's local checks do not -- entry points
# invoked by the framework, generated code, `@visibleForTesting` members -- so
# this job matches how `vulture` and `knip` are wired in the other pipelines
# (`continueOnError`). Set DART_UNUSED_FATAL=true to make it a gate.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

dart_prepare_reports "dart-unused"

TARGETS="$*"
[ -n "$TARGETS" ] || TARGETS="${DART_UNUSED_TARGETS:-lib}"

if [ ! -d "${TARGETS%% *}" ]; then
  echo "No '${TARGETS%% *}' directory found; skipping the unused-code scan."
  exit 0
fi

dart_ensure_sdk
dart_pub_get

# Prefer the project's own dev_dependency over a globally activated copy. A
# project that pins `dart_code_linter` also configures it through the
# `dart_code_linter:` section of its `analysis_options.yaml`, and running a
# different version against that configuration is how a scan starts reporting
# rules the project never enabled. Falling back to a global activation keeps the
# job useful for projects that have not adopted the dependency yet.
RUNNER=""
if grep -q 'dart_code_linter' "${DART_PUBSPEC:-pubspec.yaml}" 2>/dev/null; then
  echo "Using the project's own 'dart_code_linter' dev_dependency."
  RUNNER="project"
else
  echo "'dart_code_linter' is not a dev_dependency; activating it globally."
  echo "  Consider 'dart pub add --dev dart_code_linter' so the version is pinned with the project."
  dart_global_activate dart_code_linter metrics
  RUNNER="global"
fi

run_metrics() {
  if [ "$RUNNER" = "project" ]; then
    # shellcheck disable=SC2086
    dart_run dart run dart_code_linter:metrics "$@"
  else
    # shellcheck disable=SC2086
    dart_run metrics "$@"
  fi
}

EXIT_CODE=0

echo ""
echo "--- Unused code ---"
# shellcheck disable=SC2086
run_metrics check-unused-code $TARGETS --reporter=console > "$DART_TOOL_REPORT_PATH/unused-code.txt" 2>&1 \
  || EXIT_CODE=$?
cat "$DART_TOOL_REPORT_PATH/unused-code.txt"

echo ""
echo "--- Unused files ---"
UNUSED_FILES_EXIT=0
# shellcheck disable=SC2086
run_metrics check-unused-files $TARGETS --reporter=console > "$DART_TOOL_REPORT_PATH/unused-files.txt" 2>&1 \
  || UNUSED_FILES_EXIT=$?
cat "$DART_TOOL_REPORT_PATH/unused-files.txt"
[ "$EXIT_CODE" -eq 0 ] && EXIT_CODE="$UNUSED_FILES_EXIT"

if dart_is_dry_run; then
  echo "DRY RUN: no scan was performed."
  exit 0
fi

echo ""
echo "Reports written to: $DART_TOOL_REPORT_PATH"

if [ "$EXIT_CODE" -ne 0 ] && ! dart_is_truthy "${DART_UNUSED_FATAL:-false}"; then
  echo "Unused-code findings are advisory here; set DART_UNUSED_FATAL=true to fail the job on them."
  exit 0
fi

exit "$EXIT_CODE"
