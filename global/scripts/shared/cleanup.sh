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
