#!/usr/bin/env sh
#
# Turn `dart analyze --format=machine` output into CI-consumable reports.
#
#   analyze-report.sh [report-dir] < machine-format
#
# Reads the machine format on stdin and writes `analyze.json` and
# `junit-analyze.xml` into the report directory (default
# `build/reports/dart-analyze`), then prints a grouped human summary and exits
# with the gate's verdict: 1 when a finding at a fatal severity remains.
#
# Why the machine format and not the default one: `dart analyze` has three
# output formats (`default`, `json`, `machine`). The default one is explicitly
# documented as unstable ("the format is not specified and can change"), so
# parsing it would be building on sand. `machine` is the stable line-oriented
# contract, parsed by `analyze-report.awk`.
#
# `flutter analyze` is deliberately not used even for Flutter projects: it has
# no `--format` option at all (flutter/flutter#95090), so it can only be
# scraped. The Flutter SDK's bundled `dart` runs the same analyzer over the
# same `analysis_options.yaml`, which is why `common.sh` symlinks it.
#
# Gating: errors always fail. Warnings fail unless `DART_FATAL_WARNINGS=false`.
# Infos fail only when `DART_FATAL_INFOS=true`.

DART_ANALYZE_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)" || exit 1
DART_DIR="$(dirname "$DART_ANALYZE_DIR")"

# resolve_path <path>
#
# Where <path> really leads, as `os.path.realpath` answers it: every symlink
# along the way followed, `..` taken from wherever that left the path, and a
# missing component kept as written. Printed on stdout.
resolve_path() {
  case "$1" in
    /*) _rp_start=/ ;;
    *) _rp_start="$(pwd -P)" ;;
  esac
  resolve_walk "$_rp_start" "$1" 0
}

# resolve_walk <resolved-dir> <rest> <depth>
#
# Each symlink is resolved by a recursive call, in a command substitution so
# that every level has its own copy of these variables. A chain longer than 40
# links -- a loop -- is left unresolved where it stands.
resolve_walk() {
  _rw_path="$1"
  _rw_rest="$2"
  _rw_depth="$3"
  while [ -n "$_rw_rest" ]; do
    case "$_rw_rest" in
      */*)
        _rw_name="${_rw_rest%%/*}"
        _rw_rest="${_rw_rest#*/}"
        ;;
      *)
        _rw_name="$_rw_rest"
        _rw_rest=""
        ;;
    esac
    case "$_rw_name" in
      "" | .) continue ;;
      ..)
        _rw_path="${_rw_path%/*}"
        [ -n "$_rw_path" ] || _rw_path=/
        continue
        ;;
    esac
    if [ "$_rw_path" = / ]; then _rw_next="/$_rw_name"; else _rw_next="$_rw_path/$_rw_name"; fi
    if [ -L "$_rw_next" ] && [ "$_rw_depth" -lt 40 ] && _rw_target="$(readlink "$_rw_next")"; then
      case "$_rw_target" in
        /*) _rw_path="$(resolve_walk / "$_rw_target" $((_rw_depth + 1)))" ;;
        *) _rw_path="$(resolve_walk "$_rw_path" "$_rw_target" $((_rw_depth + 1)))" ;;
      esac
    else
      _rw_path="$_rw_next"
    fi
  done
  printf '%s\n' "$_rw_path"
}

# The report directory arrives on argv, and this script CREATES it, so
# "wherever you point me" is the wrong contract for a CI helper. `run.sh`
# passes `$DART_TOOL_REPORT_PATH`, which `common.sh` builds from
# `${PREFIX}${REPORT_PATH}` -- relative to the job's working directory in every
# runner here -- so confining it costs nothing real and makes a traversal
# (`analyze-report.sh ../../etc`) fail here rather than somewhere surprising.
# It is resolved first, so that a symlink cannot be used to step outside after
# the check.
if [ "$#" -gt 0 ]; then raw="$1"; else raw="build/reports/dart-analyze"; fi
workdir="$(pwd -P)" || exit 1
report_dir="$(resolve_path "$raw")"
case "$report_dir" in
  "$workdir" | "$workdir"/*) ;;
  *)
    printf "refusing to use '%s' as the report directory: it resolves outside the working directory '%s'\n" \
      "$raw" "$workdir" >&2
    exit 1
    ;;
esac
mkdir -p -- "$report_dir" || exit 1

# report_file <name>
#
# The report file <name> inside the directory, refusing one -- a symlink left
# in the directory -- that resolves anywhere else.
report_file() {
  _rf_path="$(resolve_path "$report_dir/$1")"
  case "$_rf_path" in
    "$report_dir" | "$report_dir"/*) printf '%s\n' "$_rf_path" ;;
    *)
      printf "refusing to write '%s' outside the report directory '%s'\n" "$1" "$report_dir" >&2
      return 1
      ;;
  esac
}

json_file="$(report_file analyze.json)" || exit 1
# The JSON report is written even when the JUnit one is refused, which is the
# order the two have always been written in.
junit_file="$(report_file junit-analyze.xml)"
junit_refused=$?
[ "$junit_refused" -eq 0 ] || junit_file=""

DART_ANALYZE_JSON="$json_file" \
  DART_ANALYZE_JUNIT="$junit_file" \
  LC_ALL=C awk -f "$DART_DIR/common.awk" -f "$DART_ANALYZE_DIR/analyze-report.awk"
status=$?

[ "$junit_refused" -eq 0 ] || exit 1
[ "$status" -le 1 ] || status=1
exit "$status"
