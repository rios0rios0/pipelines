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
#     scanned. Each is listed with where Checkov's HCL parser stopped and, for the
#     valid Terraform it is known to reject, the equivalent rewrite it reads.
#
# Only the `*.tf` files Terraform reads are scanned: every `*.hcl` file (Terragrunt
# configuration, `terraform test` files) is skipped, beside the repository's own
# `skip-path` entries.
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
. "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"
. "$SCRIPTS_DIR/global/scripts/shared/venv-distribution.sh"

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

# The verdict is read from Checkov's JSON report with `jq`, so a runner without it is refused
# here, before a hundred packages are installed for a report nothing could read.
if ! command -v jq > /dev/null 2>&1; then
  scan_incomplete "the verdict is read from Checkov's JSON report with jq, which is not installed here."
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
# checked against the package metadata in this venv (read without running its
# interpreter, see shared/venv-distribution.sh), never `checkov --version`.
CHECKOV_VENV="$HOME/.local/share/checkov-venv"

checkov_matches_pin() {
  [ -x "$CHECKOV_VENV/bin/checkov" ] || return 1
  [ "$(venv_distribution_version "$CHECKOV_VENV" checkov)" = "$CHECKOV_VERSION" ]
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
_ck_config_file=''
for _ck_config in .checkov.yaml .checkov.yml; do
  if [ -f "$_ck_config" ]; then
    echo "Using the repository's Checkov configuration: $_ck_config"
    set -- "$@" --config-file "$_ck_config"
    _ck_config_file="$_ck_config"
    break
  fi
done

# Terraform reads `*.tf` and `*.tf.json` and nothing else, but Checkov's Terraform runner parses
# every `*.hcl` file as Terraform too: Terragrunt's `terragrunt.hcl` and `root.hcl`, the
# `*.tftest.hcl` files `terraform test` runs, Packer templates. None of them is infrastructure
# Terraform deploys, none yields a check, and syntax Terraform never has to read there (a
# Terragrunt `exclude { if = ... }`, a test file's `run` blocks) only ever produced parse errors --
# each one a finding nobody could fix. So they are skipped. A `--skip-path` on the command line
# REPLACES the configuration file's `skip-path` list rather than adding to it, so the repository's
# own entries are passed again beside this one.
#
# They are read with mikefarah/yq: the one on PATH, or the pinned release, downloaded and verified
# into a directory removed after the read. `skip-path` is a path or a list of paths; any other
# shape is refused rather than guessed at, exactly as a file yq cannot parse is.
if [ -n "$_ck_config_file" ]; then
  _ck_yq_dir=$(mktemp -d) || scan_incomplete "could not create a directory to resolve yq into."
  YQ=''
  if ! resolve_yq "$_ck_yq_dir/bin"; then
    rm -rf "$_ck_yq_dir"
    scan_incomplete "yq, which reads the skip-path entries of $_ck_config_file, could not be resolved."
  fi
  if ! "$YQ" eval '(if tag == "!!map" then .["skip-path"] else null end)
      | (if tag == "!!seq" then (.[] | select(tag != "!!null"))
         elif tag == "!!str" then .
         elif tag == "!!null" then select(false)
         else error("skip-path is neither a path nor a list of paths") end)' \
    "$_ck_config_file" > "$_ck_yq_dir/skip-path"; then
    rm -rf "$_ck_yq_dir"
    scan_incomplete "the repository's $_ck_config_file could not be read, so its skip-path entries could not be kept."
  fi
  while IFS= read -r _ck_skip; do
    [ -n "$_ck_skip" ] && set -- "$@" --skip-path "$_ck_skip"
  done < "$_ck_yq_dir/skip-path"
  rm -rf "$_ck_yq_dir"
fi
set -- "$@" --skip-path '\.hcl$'

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

# The verdict comes from the JSON report rather than from Checkov's exit code, which says nothing
# about skips without a reason or files it could not parse, and which a repository's own
# `.checkov.yaml` can soften (`soft-fail: true`). One framework gives one object and several give
# a list; a scan that found no file it could read gives a bare summary object with no `results`
# at all, and an empty value (`null`, `[]`, `""`) counts as absent wherever one is read. A report
# that is not exactly one JSON document, or whose entries are not shaped as Checkov writes them,
# leaves the scan without a verdict.
_CK_JQ_DEFS='
def report: if length == 1 then .[0] else error("the report is not one JSON document") end;
def or_else(default): if . == null or . == false or . == 0 or . == "" or . == [] or . == {} then default else . end;
def py: if . == null then "None" else tostring end;
def where: "\((if has("file_path") then .file_path else "?" end) | py):\(.file_line_range | or_else([]) | map(tostring) | join("-"))";
def findings:
  [(if type == "array" then .[] else . end) | select(type == "object") | (.results | or_else({}))] as $results
  | {
      failed: [$results[] | (.failed_checks | or_else([]))[]],
      unreasoned: [$results[] | (.skipped_checks | or_else([]))[]
        | select((.check_result | or_else({})).suppress_comment | or_else("") | gsub("^\\s+|\\s+$"; "")
          | . == "" or . == "No comment provided")],
      unparsed: [$results[] | (.parsing_errors | or_else([]))[]]
    };
report | findings
'
_ck_counts=$(jq -r -s "$_CK_JQ_DEFS"'| "\(.failed | length) \(.unreasoned | length) \(.unparsed | length)"' "$jsonFile") \
  || scan_incomplete "Checkov's JSON report ($jsonFile) could not be read."
_ck_failed=${_ck_counts%% *}
_ck_unparsed=${_ck_counts##* }
_ck_unreasoned=${_ck_counts#* }
_ck_unreasoned=${_ck_unreasoned%% *}

# checkov_rewrite_hints <line> <file>
#
# Valid Terraform that Checkov's HCL parser (bc-python-hcl2) rejects, and the rewrite -- one that
# Terraform reads identically -- that gets the file scanned. Each test looks at the line the parser
# stopped on and the one before it, since an exponent is reported on the line that follows it.
checkov_rewrite_hints() {
  awk -v line="$1" '
    BEGIN {
      hint[1] = "a conditional whose \047?\047 or \047:\047 starts a line after a unary operator such as \047!\047 in its condition" \
        " (bridgecrewio/python-hcl2#153): end the line before with the operator instead"
      hint[2] = "a number in scientific notation, which the parser cannot read: write it as a plain decimal" \
        " (1e-07 as 0.0000001)"
      hint[3] = "\047if\047 or \047for\047 as an unquoted object key, which the parser reads as a keyword: quote it (\047\"if\" = ...\047)"
    }
    NR >= line - 1 && NR <= line {
      if ($0 ~ /^[[:space:]]*[?:]/) hit[1] = 1
      if ($0 ~ /(^|[^[:alnum:]_.])[0-9]+(\.[0-9]+)?[eE][+-]?[0-9]+([^[:alnum:]_.]|$)/) hit[2] = 1
      if ($0 ~ /^[[:space:]]*(if|for)[[:space:]]*=/) hit[3] = 1
    }
    NR >= line { exit }
    END { for (i = 1; i <= 3; i++) if (i in hit) print "likely cause: " hint[i] }
  ' "$2"
}

if [ "$_ck_unreasoned" -gt 0 ]; then
  echo ""
  echo "Checks skipped WITHOUT a reason -- write it as #checkov:skip=<ID>:<reason>:"
  jq -r -s "$_CK_JQ_DEFS"'| .unreasoned[] | "  \(.check_id | py)  \(.resource | py)  \(where)"' "$jsonFile"
fi
if [ "$_ck_unparsed" -gt 0 ]; then
  echo ""
  echo "Files Checkov could not parse, and so did not scan:"
  _ck_diagnosis=$(mktemp -d) || scan_incomplete "could not create a directory for the parser's diagnosis."
  jq -r -s "$_CK_JQ_DEFS"'| .unparsed[] | py' "$jsonFile" > "$_ck_diagnosis/names"
  set --
  while IFS= read -r _ck_name; do
    set -- "$@" "$_ck_name"
  done < "$_ck_diagnosis/names"

  # THE ONE PLACE THIS RUNNER RUNS PYTHON, and the reason it has to: where a file failed to parse
  # is known only to the parser that failed, and Checkov's is bc-python-hcl2, a Python library
  # that exists nowhere but inside Checkov's own virtualenv. So that interpreter is asked once,
  # about every unparsed file, and answers one line per file, in order:
  #
  #   parsed                         the parser reads the file on its own
  #   unreadable                     the file could not be opened or decoded
  #   error<TAB><line><TAB><message> where the parser stopped (0 when it says no line), and why
  #
  # and nothing at all when the parser cannot be imported. The rewrite each error suggests is read
  # from the file here. Only a file that failed to parse is asked about, and a failed answer costs
  # the notes, never the verdict.
  "$CHECKOV_VENV/bin/python" - "$@" > "$_ck_diagnosis/records" <<'PY'
import sys

try:
    import hcl2
except ImportError:
    sys.exit(0)

for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, ValueError):
        print("unreadable")
        continue
    try:
        hcl2.loads(text)
    except Exception as error:  # lark raises several types, and the parser adds its own
        message = (str(error).strip().splitlines() or [type(error).__name__])[0]
        line = getattr(error, "line", None)
        print("error\t%d\t%s" % (line if isinstance(line, int) and line > 0 else 0, message))
    else:
        print("parsed")
PY

  _ck_tab=$(printf '\t')
  _ck_rewrites=false
  exec 3< "$_ck_diagnosis/records"
  for _ck_name in "$@"; do
    printf '  %s\n' "$_ck_name"
    IFS= read -r _ck_record <&3 || _ck_record=''
    case "$_ck_record" in
      parsed)
        echo "      the parser reads this file on its own; run Checkov on it with LOG_LEVEL=DEBUG to see why it was not"
        ;;
      "error$_ck_tab"*)
        _ck_record=${_ck_record#"error$_ck_tab"}
        _ck_line=${_ck_record%%"$_ck_tab"*}
        printf '      %s\n' "${_ck_record#*"$_ck_tab"}"
        if [ "$_ck_line" -gt 0 ] 2> /dev/null; then
          _ck_hints=$(checkov_rewrite_hints "$_ck_line" "$_ck_name")
          if [ -n "$_ck_hints" ]; then
            printf '%s\n' "$_ck_hints" | sed 's/^/      /'
            _ck_rewrites=true
          fi
        fi
        ;;
    esac
  done
  exec 3<&-
  rm -rf "$_ck_diagnosis"
  if [ "$_ck_rewrites" = true ]; then
    echo "Each rewrite named above is valid Terraform that Terraform reads exactly as before."
  fi
fi
echo ""
echo "Checkov: $_ck_failed failed check(s), $_ck_unreasoned skip(s) without a reason, $_ck_unparsed file(s) it could not parse."

if [ "$_ck_failed" -eq 0 ] && [ "$_ck_unreasoned" -eq 0 ] && [ "$_ck_unparsed" -eq 0 ]; then
  echo "Checkov analysis complete: nothing to report. Results written to: $REPORT_PATH"
  exit 0
fi

echo "Results written to: $REPORT_PATH"
if [ "$CHECKOV_BLOCKING" = "true" ]; then
  echo "CHECKOV FAILED: fix what is listed above. A deliberate exception is recorded beside its resource as '#checkov:skip=<ID>:<reason>'." >&2
  exit 1
fi
echo "WARNING: Checkov reported the findings above. It is advisory here, so they do not fail the job; set CHECKOV_BLOCKING=true to make them." >&2
github_warning "findings reported in advisory mode; see the job log and the 'checkov' artifact. Set CHECKOV_BLOCKING=true to make them fail the job."
exit 0
