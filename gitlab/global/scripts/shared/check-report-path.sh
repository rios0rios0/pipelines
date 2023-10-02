#!/usr/bin/env sh

if [ -z "$REPORT_PATH" ]; then
  exit 100
fi

rm -rf "$REPORT_PATH"
mkdir -p "$REPORT_PATH" # CI/CD variable
