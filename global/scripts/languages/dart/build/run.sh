#!/usr/bin/env sh
set -e

# Artifact builder for the `40-delivery` stage.
#
# Usage: run.sh [target ...]      (default: DART_BUILD_TARGETS, else auto)
#
# Flutter targets: apk appbundle web linux macos windows ipa
# Dart targets:    exe js aot-snapshot
#
# Dispatch is by FUNCTION NAME rather than a `case` chain -- the shell's version
# of the mapper pattern. Adding a target means adding a `dart_build_<target>`
# function and nothing else: no existing branch is edited, and the list of
# supported targets is derivable from the functions that exist. A `case` with
# nine arms would have to be reopened for every new one.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

dart_prepare_reports "dart-build"

# `--build-name` is the user-visible version and `--build-number` the internal
# one both app stores order releases by. Defaulting the name from `pubspec.yaml`
# keeps the shipped artifact's version honest without asking the pipeline to
# repeat it; the number defaults to the CI build counter, which is monotonic on
# every platform here.
BUILD_NAME="${DART_BUILD_NAME:-$(dart_pubspec_field version | sed 's/+.*//')}"
BUILD_NUMBER="${DART_BUILD_NUMBER:-${BUILD_BUILDID:-${CI_PIPELINE_IID:-${GITHUB_RUN_NUMBER:-}}}}"
BUILD_MODE="${DART_BUILD_MODE:---release}"

# Resolved once into a plain variable rather than recomputed by a command
# substitution at each call site: the flags have to word-split to reach the CLI
# as separate arguments, and an unquoted `$(...)` splitting is exactly what
# ShellCheck's SC2046 flags (with no way to say "this splitting is intended",
# unlike SC2086 for a variable).
VERSION_FLAGS=""
[ -n "$BUILD_NAME" ] && VERSION_FLAGS="$VERSION_FLAGS --build-name=$BUILD_NAME"
[ -n "$BUILD_NUMBER" ] && VERSION_FLAGS="$VERSION_FLAGS --build-number=$BUILD_NUMBER"

dart_build_apk() {
  # shellcheck disable=SC2086
  dart_run flutter build apk $BUILD_MODE $VERSION_FLAGS $DART_BUILD_ARGS
}

dart_build_appbundle() {
  # shellcheck disable=SC2086
  dart_run flutter build appbundle $BUILD_MODE $VERSION_FLAGS $DART_BUILD_ARGS
}

dart_build_web() {
  # shellcheck disable=SC2086
  dart_run flutter build web $BUILD_MODE $VERSION_FLAGS $DART_BUILD_ARGS
}

dart_build_linux() {
  # shellcheck disable=SC2086
  dart_run flutter build linux $BUILD_MODE $VERSION_FLAGS $DART_BUILD_ARGS
}

dart_build_macos() {
  # shellcheck disable=SC2086
  dart_run flutter build macos $BUILD_MODE $VERSION_FLAGS $DART_BUILD_ARGS
}

dart_build_windows() {
  # shellcheck disable=SC2086
  dart_run flutter build windows $BUILD_MODE $VERSION_FLAGS $DART_BUILD_ARGS
}

dart_build_ipa() {
  # An unsigned archive is the only thing a Linux or unsigned macOS runner can
  # produce; signing needs a provisioning profile the pipeline does not hold.
  # shellcheck disable=SC2086
  dart_run flutter build ipa $BUILD_MODE --no-codesign $VERSION_FLAGS $DART_BUILD_ARGS
}

dart_build_exe() {
  _entry="${DART_ENTRYPOINT:-$(dart_default_entrypoint)}"
  if [ -z "$_entry" ]; then
    echo "ERROR: no entry point found for the 'exe' target." >&2
    echo "Expected a file under bin/ (or set DART_ENTRYPOINT)." >&2
    exit 1
  fi
  mkdir -p build
  _name="$(basename "$_entry" .dart)"
  # shellcheck disable=SC2086
  dart_run dart compile exe "$_entry" -o "build/$_name" $DART_BUILD_ARGS
}

dart_build_js() {
  _entry="${DART_ENTRYPOINT:-$(dart_default_entrypoint)}"
  mkdir -p build
  # shellcheck disable=SC2086
  dart_run dart compile js "$_entry" -o "build/main.js" $DART_BUILD_ARGS
}

dart_build_aot_snapshot() {
  _entry="${DART_ENTRYPOINT:-$(dart_default_entrypoint)}"
  mkdir -p build
  _name="$(basename "$_entry" .dart)"
  # shellcheck disable=SC2086
  dart_run dart compile aot-snapshot "$_entry" -o "build/$_name.aot" $DART_BUILD_ARGS
}

# dart_default_entrypoint
#
# A pub package's executables live in `bin/`. Prefer one named after the package
# (the pub convention), then a lone `bin/*.dart`, then `bin/main.dart`.
dart_default_entrypoint() {
  _de_name="$(dart_pubspec_field name)"
  if [ -n "$_de_name" ] && [ -f "bin/$_de_name.dart" ]; then
    printf 'bin/%s.dart' "$_de_name"
    return 0
  fi
  _de_count="$(find bin -maxdepth 1 -name '*.dart' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$_de_count" = "1" ]; then
    find bin -maxdepth 1 -name '*.dart' 2>/dev/null | head -n 1
    return 0
  fi
  [ -f "bin/main.dart" ] && printf 'bin/main.dart'
  return 0
}

TARGETS="$*"
if [ -z "$TARGETS" ]; then
  TARGETS="${DART_BUILD_TARGETS:-}"
fi

dart_ensure_sdk
dart_pub_get

# With nothing requested, build the one artifact the project's own shape implies
# rather than guessing a list. A Flutter app almost always wants an APK from
# Linux CI; a pure Dart package with a `bin/` wants a native executable; a
# library has nothing to build and should not fail for it.
if [ -z "$TARGETS" ]; then
  if [ "$DART_TOOLCHAIN" = "flutter" ]; then
    TARGETS="apk"
  elif [ -n "$(dart_default_entrypoint)" ]; then
    TARGETS="exe"
  else
    echo "No build target requested and this package declares no executable; nothing to build."
    echo "Set DART_BUILD_TARGETS (e.g. 'web appbundle') to build explicitly."
    exit 0
  fi
  echo "No build target requested; defaulting to '$TARGETS' for this $DART_TOOLCHAIN project."
fi

for target in $TARGETS; do
  # `-` is legal in a target name but not in a function name.
  handler="dart_build_$(printf '%s' "$target" | tr '-' '_')"
  if ! command -v "$handler" > /dev/null 2>&1; then
    echo "ERROR: unknown build target '$target'." >&2
    echo "Supported: apk appbundle web linux macos windows ipa exe js aot-snapshot" >&2
    exit 1
  fi
  echo ""
  echo "=== Building '$target' ==="
  "$handler"
done

if dart_is_dry_run; then
  echo "DRY RUN: nothing was built."
  exit 0
fi

echo ""
echo "Build output:"
find build -maxdepth 4 \
  \( -name '*.apk' -o -name '*.aab' -o -name '*.ipa' -o -name '*.js' -o -name '*.aot' \) \
  -print 2>/dev/null | sed 's/^/  /' || true
[ -d build/web ] && echo "  build/web/ (Flutter web bundle)"
exit 0
