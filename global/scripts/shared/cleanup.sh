#!/usr/bin/env sh

if [ -z "$REPORT_PATH" ]; then
  export REPORT_PATH="build/reports"
fi
rm -rf "$REPORT_PATH" && mkdir -p "$REPORT_PATH"
