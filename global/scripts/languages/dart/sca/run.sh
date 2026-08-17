#!/usr/bin/env sh
set -e

# Dependency vulnerability scanning for pub packages, via OSV-Scanner.
#
# This is the Dart member of the family that already holds `govulncheck` (Go),
# `safety` (Python) and OWASP Dependency-Check (Java): the language-native SCA
# for pub. OSV queries the Pub advisory database that the Dart team publishes
# into OSV.dev directly. It is the ONLY dependency scanner Dart has here --
# OWASP Dependency-Check ships no pub analyzer.
#
# OSV-Scanner is fetched as a self-contained release binary from the project's
# GitHub releases -- the same install shape as gitleaks, hadolint and shellcheck,
# and for the same reason: no Docker Hub pull, so no anonymous rate limit can
# fail the job for a reason unrelated to the dependencies under scan.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

dart_prepare_reports "osv-scanner"
REPORT_FILE="$DART_TOOL_REPORT_PATH/osv-scanner.json"
LOCKFILE="${DART_LOCKFILE:-pubspec.lock}"

# `pubspec.lock` is what OSV resolves against; `pubspec.yaml` alone carries
# version RANGES, which cannot be matched to an advisory. Applications commit
# the lockfile; published packages conventionally do not, so this is a skip
# rather than a failure.
if [ ! -f "$LOCKFILE" ]; then
  echo "No '$LOCKFILE' found; skipping the OSV dependency scan." >&2
  echo "  Applications should commit pubspec.lock so their exact dependency set can be scanned." >&2
  printf '{"results":[],"skipped":"no %s"}\n' "$LOCKFILE" > "$REPORT_FILE"
  exit 0
fi

case "$(uname -m)" in
  x86_64 | amd64) OSV_ARCH="amd64" ;;
  aarch64 | arm64) OSV_ARCH="arm64" ;;
  *)
    echo "ERROR: OSV-Scanner publishes no Linux binary for architecture '$(uname -m)'." >&2
    exit 1
    ;;
esac

mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" && export PATH ;;
esac

if ! command -v osv-scanner > /dev/null 2>&1; then
  if dart_is_dry_run; then
    echo "DRY RUN: skipping the OSV-Scanner download."
  else
    # PINNED and CHECKSUM-VERIFIED. `releases/latest/download/...` meant the
    # only dependency scanner Dart has here changed version without a diff,
    # so a lockfile could pass one day and fail the next on advisories that
    # were already public -- with nothing recording which scanner had run.
    . "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
    . "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

    case "$OSV_ARCH" in
      amd64) OSV_DIGEST_ARCH="AMD64" ;;
      arm64) OSV_DIGEST_ARCH="ARM64" ;;
    esac
    OSV_SHA256=$(pinned_digest OSV_SCANNER "$OSV_DIGEST_ARCH") || exit 1

    echo "Installing OSV-Scanner v$OSV_SCANNER_VERSION (linux/$OSV_ARCH)..."
    if ! download_verified \
      "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_$OSV_ARCH" \
      /tmp/osv-scanner \
      "$OSV_SHA256"; then
      exit 1
    fi
    chmod +x /tmp/osv-scanner
    mv /tmp/osv-scanner "$HOME/.local/bin/osv-scanner"
  fi
fi

echo "Scanning '$LOCKFILE' against the OSV Pub advisory database..."

# JSON goes to stdout and everything else to stderr, which upstream documents as
# making the redirect safe.
if dart_is_dry_run; then
  dart_run osv-scanner scan --format json --lockfile "$LOCKFILE"
  echo "DRY RUN: no scan was performed."
  exit 0
fi

# Only STDOUT is captured. Upstream documents the split -- "Outputs the results
# as a JSON object to stdout, with all other output being directed to stderr -
# this makes it safe to redirect the output to a file" -- so folding stderr in
# with `2>&1` would put progress lines inside the JSON document and leave `jq`
# (and Dependency-Track, and any reviewer) with an unparseable report.
SCAN_EXIT=0
dart_run osv-scanner scan --format json --lockfile "$LOCKFILE" > "$REPORT_FILE" || SCAN_EXIT=$?

# OSV-Scanner's exit codes are documented and NOT a simple pass/fail:
#
#   0        clean
#   1-126    vulnerabilities/findings (1 in practice)
#   127      general error
#   128      no packages found
#   129-255  non-result errors
#
# 128 is the one that must not fail the job. A `pubspec.lock` holding only
# SDK-provided dependencies produces it, and treating "nothing to scan" as a
# vulnerability would make the job red for a repository with no third-party
# dependencies at all -- the safest possible dependency set.
if [ "$SCAN_EXIT" -eq 0 ]; then
  echo "OSV-Scanner found no known vulnerabilities."
elif [ "$SCAN_EXIT" -eq 128 ]; then
  echo "OSV-Scanner found no packages to scan in '$LOCKFILE'; nothing to report."
  SCAN_EXIT=0
elif [ "$SCAN_EXIT" -eq 127 ] || [ "$SCAN_EXIT" -ge 129 ]; then
  echo "ERROR: OSV-Scanner failed to run (exit $SCAN_EXIT)." >&2
  [ -s "$REPORT_FILE" ] && head -50 "$REPORT_FILE" >&2
else
  echo "OSV-Scanner reported vulnerable dependencies:"
  # Render the findings back into the log. Without this the job goes red having
  # named not one package, and the only way to learn what broke is to download
  # the artifact.
  if command -v jq > /dev/null 2>&1 && jq -e . "$REPORT_FILE" > /dev/null 2>&1; then
    jq -r '
      .results[]?.packages[]? as $p
      | $p.vulnerabilities[]?
      | "  - \($p.package.name) \($p.package.version): \(.id) \(.summary // "")"
    ' "$REPORT_FILE" | sort -u
  else
    head -100 "$REPORT_FILE"
  fi
fi

echo "Report written to: $REPORT_FILE"
exit "$SCAN_EXIT"
