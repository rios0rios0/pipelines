#!/usr/bin/env sh
#
# Checkov: misconfiguration scanning for Terraform.
#
# WHY CHECKOV. Trivy was this repository's infrastructure-as-code scanner until
# it was removed after its releases and its GitHub Action's tags were
# compromised. Nothing replaced it, so a Terraform pipeline checked formatting,
# lint and syntax but never asked whether a bucket was public or an IAM
# statement too broad. Checkov is maintained, models the major clouds' resources
# (OCI included), and is installed here the way that compromise teaches: a
# pinned version, a digest verified before anything runs, a virtualenv of its
# own, and no third-party action.
#
# ADVISORY UNLESS ASKED TO BLOCK. Every other tool here fails on a finding and
# leaves the advisory-versus-blocking choice to the call site. A scanner that is
# new to every consumer at once cannot start that way: each consumer's existing
# findings would turn its pipeline red the day this lands, before anyone could
# triage them. So findings fail the scan only when `CHECKOV_BLOCKING=true`, the
# switch each consumer turns on once its findings are fixed or recorded.
# Otherwise they are reported -- in the log, in the reports, and as a warning
# annotation on GitHub -- and the scan exits 0. In advisory mode a scan that
# cannot complete (no Python, a refused download) is a warning too: nothing this
# script does fails a pipeline that has not opted in.
#
# WHAT COUNTS AS A FINDING:
#   * a failed check;
#   * a check skipped without a reason. `#checkov:skip=<ID>:<reason>` beside the
#     resource is how a deliberate exception is recorded, and the reason is the
#     record. Checkov itself accepts `#checkov:skip=<ID>` alone and files it as
#     "No comment provided";
#   * a file Checkov could not parse. Checkov lists it and exits 0, so syntax it
#     does not understand would otherwise read as a clean scan of a file nobody
#     scanned.
#
# Settings (environment):
#   CHECKOV_BLOCKING     `true` makes findings fail the scan; `false` (default)
#   CHECKOV_DIRECTORIES  space-separated directories to scan, recursively (default `.`)
#
# A `.checkov.yaml` (or `.checkov.yml`) in the working directory is handed to
# Checkov as its configuration, so repository-wide settings live there. Its
# `skip-check` list is honoured, but Checkov records no reason for those, so a
# deliberate exception belongs inline beside its resource instead.
#
# Reports: `build/reports/checkov/checkov.sarif` and `checkov.json`.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="checkov" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

sarifFile="$REPORT_PATH/checkov.sarif"
jsonFile="$REPORT_PATH/checkov.json"

CHECKOV_BLOCKING="${CHECKOV_BLOCKING:-false}"
CHECKOV_DIRECTORIES="${CHECKOV_DIRECTORIES:-.}"

# A typo must not quietly mean "advisory": a consumer that wrote `ture` asked for
# blocking, and reading it as `false` would pass every finding without a word.
case "$CHECKOV_BLOCKING" in
  true | false) ;;
  *)
    echo "ERROR: CHECKOV_BLOCKING must be 'true' or 'false', not '$CHECKOV_BLOCKING'." >&2
    exit 1
    ;;
esac

# github_warning <message>
#
# A warning annotation when running on GitHub Actions, where it shows on the run's
# summary page instead of only in a step log that a passing job never makes
# anyone open. Anywhere else, nothing.
github_warning() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::warning title=Checkov::$1"
  fi
}

# scan_incomplete <message>
#
# The scan could not reach a verdict. Blocking, that fails it; advisory, it is a
# warning, which is the promise advisory mode makes.
scan_incomplete() {
  echo "ERROR: $1" >&2
  if [ "$CHECKOV_BLOCKING" = "true" ]; then
    exit 1
  fi
  echo "Checkov is advisory here (CHECKOV_BLOCKING is not 'true'), so this does not fail the job." >&2
  github_warning "the scan did not complete: $1"
  exit 0
}

for _ck_dir in $CHECKOV_DIRECTORIES; do
  if [ ! -d "$_ck_dir" ]; then
    scan_incomplete "CHECKOV_DIRECTORIES names '$_ck_dir', which is not a directory here."
  fi
done

# Skip, rather than install a hundred packages to scan nothing, when there is no
# Terraform to read. Hidden directories (`.terraform/` caches, `.git/`, a
# `.terragrunt-cache/`) and `node_modules/` are left out, as Checkov leaves them.
_ck_found=''
for _ck_dir in $CHECKOV_DIRECTORIES; do
  _ck_found=$(find "$_ck_dir" \
    \( -type d \( -name '.?*' -o -name 'node_modules' \) ! -path "$_ck_dir" -prune \) \
    -o \( -type f -name '*.tf' -print \) 2> /dev/null | head -n 1)
  [ -n "$_ck_found" ] && break
done
if [ -z "$_ck_found" ]; then
  echo "No Terraform files found under: $CHECKOV_DIRECTORIES -- skipping Checkov."
  cat > "$sarifFile" <<'EOF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "Checkov",
          "informationUri": "https://www.checkov.io",
          "rules": []
        }
      },
      "results": []
    }
  ]
}
EOF
  echo "Empty report written to: $sarifFile"
  exit 0
fi

# Install Checkov into a virtualenv of its own when the pinned version is not
# already there. It is a PyPI package with no standalone binary, and a venv keeps
# it clear of the PEP 668 "externally-managed-environment" refusal and of the
# runner's own Python. The venv persists under ~/.local/share, so a persistent
# runner installs once per pin.
#
# The release's wheel is downloaded by name and refused unless its SHA-256 matches
# the digest committed in `pinned-versions.sh`; pip then installs that verified
# FILE, binary-only (`--only-binary :all:` -- an sdist runs its build script AS
# PART OF THE INSTALL). The scan runs the venv's own launcher by path, so another
# `checkov` on PATH can neither shadow the pin nor satisfy it, and the pin is
# checked against the package metadata in this venv, never `checkov --version`.
CHECKOV_VENV="$HOME/.local/share/checkov-venv"

checkov_matches_pin() {
  [ -x "$CHECKOV_VENV/bin/checkov" ] || return 1
  _ck_current=$("$CHECKOV_VENV/bin/python" -c \
    'import importlib.metadata as m; print(m.version("checkov"))' 2> /dev/null)
  [ "$_ck_current" = "$CHECKOV_VERSION" ]
}

if ! checkov_matches_pin; then
  if ! command -v python3 > /dev/null 2>&1; then
    scan_incomplete "Checkov needs Python 3 (it ships no binary). Install python3 and re-run."
  fi
  if [ ! -x "$CHECKOV_VENV/bin/pip" ] && ! python3 -m venv "$CHECKOV_VENV"; then
    scan_incomplete "could not create the Checkov virtualenv at $CHECKOV_VENV. On Debian and Ubuntu this usually means the python3-venv package is absent."
  fi
  CHECKOV_WHEEL_SHA256=$(pinned_digest CHECKOV "") \
    || scan_incomplete "there is no digest to verify the Checkov $CHECKOV_VERSION wheel against."
  _ck_download_dir=$(mktemp -d) || scan_incomplete "could not create a directory to download Checkov into."
  _ck_wheel="$_ck_download_dir/checkov-$CHECKOV_VERSION-py3-none-any.whl"
  echo "Installing Checkov $CHECKOV_VERSION..."
  if ! download_verified \
    "https://files.pythonhosted.org/packages/py3/c/checkov/checkov-${CHECKOV_VERSION}-py3-none-any.whl" \
    "$_ck_wheel" \
    "$CHECKOV_WHEEL_SHA256"; then
    rm -rf "$_ck_download_dir"
    scan_incomplete "the Checkov $CHECKOV_VERSION wheel could not be downloaded and verified."
  fi
  # Captured rather than silenced, so a failure still says why in pip's words.
  if ! _ck_pip_log=$("$CHECKOV_VENV/bin/pip" install --disable-pip-version-check --only-binary :all: "$_ck_wheel" 2>&1); then
    rm -rf "$_ck_download_dir"
    printf '%s\n' "$_ck_pip_log" >&2
    scan_incomplete "pip could not install the verified Checkov $CHECKOV_VERSION wheel into $CHECKOV_VENV."
  fi
  rm -rf "$_ck_download_dir"
  if ! checkov_matches_pin; then
    scan_incomplete "the virtualenv at $CHECKOV_VENV does not hold Checkov $CHECKOV_VERSION after installation."
  fi
fi

# Collect the arguments in the positional parameters, so they pass without `eval`.
set --
for _ck_dir in $CHECKOV_DIRECTORIES; do
  set -- "$@" --directory "$_ck_dir"
done
for _ck_config in .checkov.yaml .checkov.yml; do
  if [ -f "$_ck_config" ]; then
    echo "Using the repository's Checkov configuration: $_ck_config"
    set -- "$@" --config-file "$_ck_config"
    break
  fi
done

# `--skip-download` keeps the scan offline once installed: without an API key there
# is nothing of ours to fetch from the vendor's platform, only documentation links.
# `CKV_SKIP_PACKAGE_UPDATE_CHECK` stops the "update available" lookup, since the
# pin, not the tool, decides the version. `--output-file-path` maps each output in
# order: the CLI table to the console, then the JSON and the SARIF to files.
echo "Running Checkov $CHECKOV_VERSION over: $CHECKOV_DIRECTORIES"
CKV_SKIP_PACKAGE_UPDATE_CHECK=true "$CHECKOV_VENV/bin/checkov" "$@" \
  --framework terraform \
  --skip-download \
  --compact \
  --output cli --output json --output sarif \
  --output-file-path "console,$jsonFile,$sarifFile" || CHECKOV_EXIT=$?

# Checkov exits 1 for failed checks; anything else non-zero is the scan itself
# failing (an argument it refused, a crash).
case "${CHECKOV_EXIT:-0}" in
  0 | 1) ;;
  *) scan_incomplete "Checkov exited with code $CHECKOV_EXIT, which is neither a clean scan (0) nor findings (1)." ;;
esac

# The verdict comes from the JSON report rather than from Checkov's exit code,
# which says nothing about skips without a reason or files it could not parse,
# and which a repository's own `.checkov.yaml` can soften (`soft-fail: true`).
# Exits 0 when there is nothing to report, 3 when there are findings, 2 when the
# report cannot be read.
"$CHECKOV_VENV/bin/python" - "$jsonFile" <<'PY' || _ck_verdict=$?
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except (OSError, ValueError) as error:
    print("Checkov's JSON report could not be read: %s" % error, file=sys.stderr)
    sys.exit(2)

# One framework gives one object and several give a list; a scan that found no
# file it could read gives a bare summary object with no `results` at all.
documents = report if isinstance(report, list) else [report]
failed, unreasoned, unparsed = [], [], []
for document in documents:
    if not isinstance(document, dict):
        continue
    results = document.get("results") or {}
    failed.extend(results.get("failed_checks") or [])
    for check in results.get("skipped_checks") or []:
        comment = ((check.get("check_result") or {}).get("suppress_comment") or "").strip()
        if comment in ("", "No comment provided"):
            unreasoned.append(check)
    unparsed.extend(results.get("parsing_errors") or [])


def where(check):
    lines = "-".join(str(line) for line in check.get("file_line_range") or [])
    return "%s:%s" % (check.get("file_path", "?"), lines)


if unreasoned:
    print("")
    print("Checks skipped WITHOUT a reason -- write it as #checkov:skip=<ID>:<reason>:")
    for check in unreasoned:
        print("  %s  %s  %s" % (check.get("check_id"), check.get("resource"), where(check)))
if unparsed:
    print("")
    print("Files Checkov could not parse, and so did not scan:")
    for name in unparsed:
        print("  %s" % name)
print("")
print(
    "Checkov: %d failed check(s), %d skip(s) without a reason, %d file(s) it could not parse."
    % (len(failed), len(unreasoned), len(unparsed))
)
sys.exit(3 if failed or unreasoned or unparsed else 0)
PY

case "${_ck_verdict:-0}" in
  0)
    echo "Checkov analysis complete: nothing to report. Results written to: $REPORT_PATH"
    exit 0
    ;;
  3) ;;
  *) scan_incomplete "Checkov's JSON report ($jsonFile) could not be read." ;;
esac

echo "Results written to: $REPORT_PATH"
if [ "$CHECKOV_BLOCKING" = "true" ]; then
  echo "CHECKOV FAILED: fix what is listed above. A deliberate exception is recorded beside its resource as '#checkov:skip=<ID>:<reason>'." >&2
  exit 1
fi
echo "WARNING: Checkov reported the findings above. It is advisory here, so they do not fail the job; set CHECKOV_BLOCKING=true to make them." >&2
github_warning "findings reported in advisory mode; see the job log and the 'checkov' artifact. Set CHECKOV_BLOCKING=true to make them fail the job."
exit 0
