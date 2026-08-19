#!/usr/bin/env sh

if [ -z "$REPORT_PATH" ]; then
  export REPORT_PATH="build/reports"
fi

if [ -n "$TOOL_NAME" ]; then
  # If tool name given, clean only that tool's subdirectory
  TOOL_REPORT_PATH="$REPORT_PATH/$TOOL_NAME"
  rm -rf "$TOOL_REPORT_PATH" && mkdir -p "$TOOL_REPORT_PATH"
  export REPORT_PATH="$TOOL_REPORT_PATH"
else
  # If not given, clean entire report dir (legacy behaviour)
  rm -rf "$REPORT_PATH" && mkdir -p "$REPORT_PATH"
fi

# Ensure the current user's ~/.local/bin exists and is FIRST on PATH so tool
# scripts install binaries there without root and their copy is the one that
# runs. Pipeline/CI shells are frequently non-login and do not pick
# ~/.local/bin up from the user's profile, so add it here for every tool that
# sources this shared preamble.
#
# The test is for PRECEDENCE, not membership. Testing only whether the
# directory appears somewhere in PATH is not enough: a persistent or
# self-hosted runner very often already has ~/.local/bin on PATH -- from a
# login profile, a service unit, or an earlier tool -- and if it sits AFTER a
# directory holding a system-wide copy of the same tool, the membership test
# passes, this preamble does nothing, and every script that installs a PINNED
# version here is silently shadowed by whatever copy was there first. That is
# the opposite of what the tool scripts document ("our copy wins over a
# system-wide one"), and it surfaces as a version mismatch long after the
# install has apparently succeeded.
#
# Prepending when the directory is already present later in PATH leaves a
# duplicate entry, which is harmless: lookup stops at the first match.
#
# `${PATH:+:$PATH}` adds the separator only when PATH is non-empty. A plain
# ":$PATH" would leave a trailing colon on an empty PATH, and POSIX reads an
# empty PATH element as the CURRENT DIRECTORY -- which in a preamble sourced
# by tool installers that then run binaries by name, inside a checked-out
# repository, is an execution path for anything the repository ships.
mkdir -p "$HOME/.local/bin"
case "$PATH:" in
  "$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin${PATH:+:$PATH}" && export PATH ;;
esac
