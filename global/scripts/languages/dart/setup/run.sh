#!/usr/bin/env sh
set -e

# Installs the toolchain a Dart or Flutter project needs and reports what it
# resolved.
#
# Every other script in this directory calls `dart_ensure_sdk` itself, so this
# one is not a prerequisite for them -- it exists for the two cases where an
# explicit step is worth having:
#
#   - A pipeline that wants the (potentially slow) first SDK download to happen
#     in a named step, so a cold-runner install is legible in the job log
#     instead of being attributed to whichever job happened to run first.
#   - `make setup-dart` locally.
#
# The toolchain is detected from `pubspec.yaml` unless `DART_TOOLCHAIN` forces
# it. See `../common.sh` for why the SDK comes from Google's archive rather than
# a Docker image.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

dart_prepare_reports "dart-setup"
dart_ensure_sdk

echo "Toolchain: $DART_TOOLCHAIN"

if dart_is_dry_run; then
  echo "DRY RUN: no SDK was installed and no dependencies were resolved."
  exit 0
fi

if [ "$DART_TOOLCHAIN" = "flutter" ]; then
  flutter --version
  # Fail fast and readably when the SDK is unusable (missing engine artifacts,
  # a broken checkout). Without this the first real failure surfaces inside
  # `flutter test` as a stack trace that names Flutter internals rather than the
  # environment. `--no-version-check` keeps the doctor from adding a network
  # round-trip just to tell us a newer Flutter exists.
  flutter --no-version-check doctor -v || true
else
  dart --version
fi

dart_pub_get

echo "Dart/Flutter toolchain is ready."
