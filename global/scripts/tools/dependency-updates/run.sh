#!/usr/bin/env sh
# Keep every pinned third-party dependency current without ever proposing one
# known to be vulnerable or malicious.
#
# Usage:
#   run.sh                    # check this repo; exit 1 when anything needs a person
#   run.sh --report-only      # report without failing (exit 0 always)
#   run.sh --apply            # rewrite every safe update and write the pull request
#   run.sh --verify-assets    # check every `# asset:` template against its digest
#   run.sh --repo-dir /path   # target a different repository root
#   run.sh verify --base-dir /base [--repo-dir /head]
#                             # prove a pull request that moves pins safe to merge
#   run.sh guard --repository o/r --branch b --base main --fingerprint <fp>
#                             # may the update branch be regenerated?
#
# A release is proposed only once it is older than the cooldown (seven days by
# default), and never when it would introduce a known vulnerability or is a
# known malicious publication; a pin with a known vulnerability gets its fix
# proposed at once, cooldown waived. Advisories come from OSV.dev.
#
# Exit codes:
#   0  nothing needs a person
#   1  something does: an update that could not be applied safely, a pin with no
#      annotation to check it by, a known vulnerability in a pin in use, or a
#      pull request that fails verification
#   2  an upstream or the advisory database could not be consulted --
#      deliberately NOT reported as clean, because a rate-limited API must never
#      look like a green light
#
# Set GITHUB_TOKEN (or GH_TOKEN) before running: roughly forty of the lookups
# hit api.github.com, which allows 60 requests/hour unauthenticated.
#
# The command is Go, built from this checkout on every run (see
# global/scripts/shared/go-helper.sh); it needs a Go toolchain, 1.25 or newer.
set -eu

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
# Defaulted before sourcing `cleanup.sh`, which reads `$REPORT_PATH` unguarded.
REPORT_PATH="${REPORT_PATH:-build/reports}"
export REPORT_PATH

case "${1:-}" in
  guard)
    # Writes no report -- and must not clean the one the check just wrote,
    # which the workflow opens the pull request from in its next step.
    ;;
  verify)
    TOOL_NAME="dependency-updates-verify" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
    shift
    set -- verify --report "$REPORT_PATH" "$@"
    ;;
  *)
    TOOL_NAME="dependency-updates" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
    set -- --report "$REPORT_PATH" "$@"
    ;;
esac

# `--apply` and `verify` scan container image rebuilds with OSV-Scanner: the
# pinned, checksum-verified one, run by that exact path -- never whatever
# `osv-scanner` is first on PATH. The command runs the installer the first time
# an image actually needs scanning, so a pull request that moves no image
# downloads nothing, and one that moves no pin asks nothing of the network at
# all. An explicit `--osv-scanner` brings its own scanner and installs nothing.
needs_scanner=false
for argument in "$@"; do
  case "$argument" in
    verify | --apply) needs_scanner=true ;;
    *) ;;
  esac
done
# A fixture answers the scans too, so an offline run never downloads a scanner.
if [ -n "${DEPENDENCY_UPDATES_FIXTURE:-}" ]; then
  needs_scanner=false
fi
for argument in "$@"; do
  case "$argument" in
    --fixture | --fixture=* | -fixture | -fixture=* | --scan-images=false | -scan-images=false | \
      --osv-scanner | --osv-scanner=* | -osv-scanner | -osv-scanner=*)
      needs_scanner=false
      ;;
    *) ;;
  esac
done
if [ "$needs_scanner" = true ]; then
  osv_installer="$SCRIPTS_DIR/global/scripts/tools/osv-scanner/install.sh"
  if [ "$1" = verify ]; then
    shift
    set -- verify --osv-scanner "$HOME/.local/bin/osv-scanner" --osv-scanner-installer "$osv_installer" "$@"
  else
    set -- --osv-scanner "$HOME/.local/bin/osv-scanner" --osv-scanner-installer "$osv_installer" "$@"
  fi
fi

. "$SCRIPTS_DIR/global/scripts/shared/go-helper.sh"
go_helper_run global/scripts/tools/dependency-updates "$@"
