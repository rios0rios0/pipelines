#!/usr/bin/env sh
set -e

# Publishes a package to pub.dev (or a self-hosted pub server) for the
# `40-delivery` stage of the library templates.
#
# THE CREDENTIAL IS NEVER PASSED ON ARGV. `dart pub token add` accepts
# `--env-var PUB_TOKEN`, which tells pub to read the token from THAT ENVIRONMENT
# VARIABLE AT USE TIME -- the name travels on the command line, the value never
# does. Argv is world-readable through `ps` for the lifetime of the process on a
# shared or self-hosted runner, and this repository additionally records
# resolved command lines into `command.txt`, which all three platforms publish
# as a downloadable artifact. Same reasoning as `-DnvdApiKeyEnvironmentVariable`
# in the Dependency-Check runner (GHSA-qqhq-8r2c-c3f5) and as the deploy family.
#
# A dry run always precedes the real publish. `dart pub publish --dry-run`
# performs the full validation pub.dev would -- missing description, missing
# licence, unresolvable constraints, files that would be shipped by mistake --
# without uploading. Publishing to pub.dev is IRREVERSIBLE: a version can be
# retracted but never replaced or deleted, so a failed validation must stop the
# job before the upload rather than be discovered after it.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

dart_prepare_reports "dart-publish"

PUB_SERVER="${PUB_HOSTED_URL:-https://pub.dev}"
PACKAGE_NAME="$(dart_pubspec_field name)"
PACKAGE_VERSION="$(dart_pubspec_field version)"

echo "Package: ${PACKAGE_NAME:-<unknown>} ${PACKAGE_VERSION:-<unknown>}"
echo "Server:  $PUB_SERVER"

if grep -qE '^publish_to:[[:space:]]*none[[:space:]]*$' "${DART_PUBSPEC:-pubspec.yaml}" 2>/dev/null; then
  echo "pubspec.yaml sets 'publish_to: none'; this package is not meant to be published. Skipping."
  exit 0
fi

dart_ensure_sdk
dart_pub_get

echo ""
echo "=== Validating the package (dry run) ==="
dart_run dart pub publish --dry-run

if dart_is_truthy "${DART_PUBLISH_DRY_RUN:-false}" || dart_is_dry_run; then
  echo ""
  echo "Validation only; not publishing (DART_PUBLISH_DRY_RUN / DART_DRY_RUN is set)."
  exit 0
fi

if [ -z "${PUB_TOKEN:-}" ]; then
  echo "ERROR: PUB_TOKEN is not set, so the package cannot be published." >&2
  echo "  pub.dev: create a token with 'dart pub token add https://pub.dev' locally, or use a" >&2
  echo "  short-lived OIDC token via pub.dev's automated publishing. Expose it to the job as the" >&2
  echo "  secret variable PUB_TOKEN. Set DART_PUBLISH_DRY_RUN=true to validate without publishing." >&2
  exit 1
fi

echo ""
echo "=== Authenticating ==="
# The token VALUE stays in the environment; only its NAME is on argv.
dart_run dart pub token add "$PUB_SERVER" --env-var PUB_TOKEN

echo ""
echo "=== Publishing ==="
# `--force` skips the interactive confirmation, which no CI runner can answer.
# It does NOT skip validation: the dry run above already had to pass, and pub
# re-runs the same checks server-side.
dart_run dart pub publish --force

echo ""
echo "Published ${PACKAGE_NAME} ${PACKAGE_VERSION} to $PUB_SERVER."
