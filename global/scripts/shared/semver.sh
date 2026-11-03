#!/usr/bin/env sh
# shellcheck shell=sh
#
# Semantic Versioning 2.0.0 precedence, for comparing release tags.
# SOURCED, never executed -- it carries no `run.sh` name and no executable bit.
#
# Why not `git tag --sort=-v:refname` or `sort -V`: both rank `1.0.0` BELOW its
# own pre-releases, so `1.0.0-rc.1` reads as newer than the release it led to.
# git gets that case right only when `versionsort.suffix=-` is configured, and
# only over tags fetched into a local clone. The comparison below is section 11
# of the specification (https://semver.org/#spec-item-11), applied to tag names
# alone:
#
#   1. MAJOR, MINOR and PATCH compare as numbers: by length first, then digit by
#      digit, so a number past 2^53 compares exactly (awk would compare two
#      numeric strings as doubles);
#   2. a version with a pre-release ranks below the same version without one;
#   3. pre-release identifiers compare left to right: two numeric ones as
#      numbers, two alphanumeric ones in ASCII order, and a numeric one below an
#      alphanumeric one; when every identifier compared is equal, the longer
#      list ranks higher;
#   4. build metadata (`+...`) is ignored, so `1.0.0+a` and `1.0.0+b` are equal.
#
# A tag names a version when it is a SemVer 2.0.0 version, optionally preceded
# by ONE `v` (`v1.2.3`). The prefix is not part of the specification, but it is
# how much of the world spells a release tag, and the release action here
# writes it when a caller passes `tag_prefix: 'v'`. Any other prefix
# (`app/1.2.3`), a fourth number (`1.2.3.4`), a leading zero (`01.2.3`) or a
# missing part (`1.2`) is not a version, and the functions below say so rather
# than guess.
#
# awk runs under `LC_ALL=C`: POSIX awk compares strings in the collation order
# of the current locale, while the specification asks for ASCII order. Values
# reach awk through ENVIRON rather than `-v`, which would interpret backslash
# escapes in them. Only POSIX awk is used -- no interval expressions, which
# older mawk releases do not support -- and the comparisons were checked to agree
# under mawk (the Debian and Ubuntu default), GNU awk and BusyBox awk (Alpine).

# The awk functions every shell function below runs, kept in one string so the
# three cannot drift apart.
#
#   sv_version(tag)  the version a tag names (the tag minus one leading `v`), or
#                    "" when it names none
#   sv_compare(a, b) -1, 0 or 1: the precedence of version a against version b
_SEMVER_AWK='
function sv_number(s) {
  return s ~ /^(0|[1-9][0-9]*)$/
}

function sv_identifiers(list, prerelease,    count, parts, i) {
  if (list == "") return 0
  count = split(list, parts, "[.]")
  for (i = 1; i <= count; i++) {
    if (parts[i] !~ /^[0-9A-Za-z-]+$/) return 0
    if (prerelease && parts[i] ~ /^[0-9]+$/ && !sv_number(parts[i])) return 0
  }
  return 1
}

function sv_version(tag,    version, rest, at, parts) {
  version = tag
  if (substr(version, 1, 1) == "v") version = substr(version, 2)
  rest = version
  at = index(rest, "+")
  if (at > 0) {
    if (!sv_identifiers(substr(rest, at + 1), 0)) return ""
    rest = substr(rest, 1, at - 1)
  }
  at = index(rest, "-")
  if (at > 0) {
    if (!sv_identifiers(substr(rest, at + 1), 1)) return ""
    rest = substr(rest, 1, at - 1)
  }
  if (split(rest, parts, "[.]") != 3) return ""
  if (!sv_number(parts[1]) || !sv_number(parts[2]) || !sv_number(parts[3])) return ""
  return version
}

function sv_compare_numbers(a, b) {
  if (length(a) != length(b)) return length(a) < length(b) ? -1 : 1
  if ((a "") == (b "")) return 0
  return (a "") < (b "") ? -1 : 1
}

function sv_compare_identifiers(a, b,    a_numeric, b_numeric) {
  a_numeric = (a ~ /^[0-9]+$/)
  b_numeric = (b ~ /^[0-9]+$/)
  if (a_numeric && b_numeric) return sv_compare_numbers(a, b)
  if (a_numeric) return -1
  if (b_numeric) return 1
  if ((a "") == (b "")) return 0
  return (a "") < (b "") ? -1 : 1
}

function sv_compare(a, b,    at, a_pre, b_pre, a_parts, b_parts, a_count, b_count, i, order) {
  at = index(a, "+"); if (at > 0) a = substr(a, 1, at - 1)
  at = index(b, "+"); if (at > 0) b = substr(b, 1, at - 1)
  a_pre = ""; b_pre = ""
  at = index(a, "-"); if (at > 0) { a_pre = substr(a, at + 1); a = substr(a, 1, at - 1) }
  at = index(b, "-"); if (at > 0) { b_pre = substr(b, at + 1); b = substr(b, 1, at - 1) }
  split(a, a_parts, "[.]")
  split(b, b_parts, "[.]")
  for (i = 1; i <= 3; i++) {
    order = sv_compare_numbers(a_parts[i], b_parts[i])
    if (order != 0) return order
  }
  if (a_pre == "" && b_pre == "") return 0
  if (a_pre == "") return 1
  if (b_pre == "") return -1
  a_count = split(a_pre, a_parts, "[.]")
  b_count = split(b_pre, b_parts, "[.]")
  for (i = 1; i <= a_count && i <= b_count; i++) {
    order = sv_compare_identifiers(a_parts[i], b_parts[i])
    if (order != 0) return order
  }
  if (a_count == b_count) return 0
  return a_count < b_count ? -1 : 1
}
'

# semver_version <tag>
#
# Prints the version the tag names -- the tag without one leading `v` -- and
# returns 0, or prints nothing and returns 1 when the tag names no SemVer 2.0.0
# version.
semver_version() {
  SEMVER_TAG="${1-}" LC_ALL=C awk "$_SEMVER_AWK"'
    BEGIN {
      version = sv_version(ENVIRON["SEMVER_TAG"])
      if (version == "") exit 1
      print version
    }'
}

# semver_compare <a> <b>
#
# Prints -1, 0 or 1: the precedence of the version tag `a` names against the one
# tag `b` names (`v1.0.0` and `1.0.0` are equal). Returns 1 and prints nothing
# when either names no version.
semver_compare() {
  SEMVER_A="${1-}" SEMVER_B="${2-}" LC_ALL=C awk "$_SEMVER_AWK"'
    BEGIN {
      a = sv_version(ENVIRON["SEMVER_A"])
      b = sv_version(ENVIRON["SEMVER_B"])
      if (a == "" || b == "") exit 1
      print sv_compare(a, b)
    }'
}

# semver_highest
#
# Reads tags from stdin, one per line, and prints the one naming the version of
# highest precedence, spelled as it was read. Blank lines, surrounding blanks
# and every tag naming no version are skipped; when no tag names one, it prints
# nothing and still returns 0. Of tags of equal precedence (`1.0.0` and
# `v1.0.0`), the first read is printed.
semver_highest() {
  LC_ALL=C awk "$_SEMVER_AWK"'
    {
      tag = $0
      gsub(/^[ \t\r]+|[ \t\r]+$/, "", tag)
      version = sv_version(tag)
      if (version == "") next
      if (best == "" || sv_compare(version, best_version) > 0) {
        best = tag
        best_version = version
      }
    }
    END { if (best != "") print best }'
}
