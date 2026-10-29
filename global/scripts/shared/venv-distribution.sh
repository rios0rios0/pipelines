#!/usr/bin/env sh
# shellcheck shell=sh
#
# Answers which version of a Python distribution a virtualenv holds, without
# running the virtualenv's interpreter. SOURCED, never executed -- it carries no
# `run.sh` name and no executable bit.
#
# Semgrep and Checkov are Python programs with no standalone binary, so each is
# installed into a virtualenv of its own, and each runner checks that the venv
# holds the PINNED version before trusting it. That check must not ask the tool
# itself: `semgrep --version` can disagree with the installed distribution (see
# semgrep/run.sh). The authority is the metadata pip wrote: the `Version:` field
# of `<name>-<version>.dist-info/METADATA`, which is the same file `pip show`
# and `importlib.metadata.version()` read. Reading it here needs no Python.
#
#   venv_distribution_version <venv directory> <distribution name>
#
# Prints the version and returns 0. A venv holding no such distribution, or more
# than one (a broken install), prints a description in angle brackets instead:
# no pin can equal it, so a caller comparing the output with its pin reinstalls,
# and a caller reporting it says what it found.

venv_distribution_version() {
  _vdv_found=''
  # `<name>-[0-9]*`: a version always starts with a digit, so another
  # distribution whose name merely begins with `<name>-` is never read.
  for _vdv_metadata in "$1"/lib/python*/site-packages/"$2"-[0-9]*.dist-info/METADATA; do
    [ -f "$_vdv_metadata" ] || continue
    if [ -n "$_vdv_found" ]; then
      echo "<more than one $2 distribution>"
      return 0
    fi
    _vdv_found="$_vdv_metadata"
  done
  if [ -z "$_vdv_found" ]; then
    echo "<no $2 distribution>"
    return 0
  fi
  sed -n 's/^Version: *//p' "$_vdv_found" | head -n 1
}
