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

# Ensure the current user's ~/.local/bin exists and is on PATH so tool scripts
# install binaries there without root. Pipeline/CI shells are frequently
# non-login and do not pick ~/.local/bin up from the user's profile, so add it
# here (idempotently) for every tool that sources this shared preamble.
mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" && export PATH ;;
esac
