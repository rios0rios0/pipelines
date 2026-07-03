#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="semgrep" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

SEMGREP_LANGUAGE="$1" # it takes the first param as the main language
fileName="$REPORT_PATH/semgrep.json"

# TODO: Should we merge files?
# Use the default ignore file if the project doesn't provide one.
ignoreFileExists=true
if [ ! -f ".semgrepignore" ]; then
  ignoreFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/semgrep/.semgrepignore"
  cp "$defaultFile" .
fi

# Install Semgrep if not already available. Semgrep has no standalone binary
# release -- it is distributed as a Python package -- so it is installed from
# PyPI rather than being pulled as a Docker image. Docker Hub now enforces an
# anonymous pull rate limit, which made every uncached CI run risk a
# `toomanyrequests` failure. Semgrep is installed into an isolated virtualenv:
# a venv sidesteps the PEP 668 "externally-managed-environment" restriction on
# modern distributions without polluting the runner's system Python.
if ! command -v semgrep > /dev/null 2>&1; then
  if ! command -v python3 > /dev/null 2>&1; then
    echo "ERROR: Semgrep requires Python 3 (it has no standalone binary release). Install python3 and re-run." >&2
    exit 1
  fi
  echo "Downloading Semgrep..."
  SEMGREP_VENV="/tmp/semgrep-venv"
  python3 -m venv "$SEMGREP_VENV"
  "$SEMGREP_VENV/bin/pip" install --quiet --disable-pip-version-check semgrep
  export PATH="$SEMGREP_VENV/bin:$PATH"
else
  # Already present (persistent agent): self-update so long-lived hosts stay
  # current for CVE fixes. Prefer our own venv if it survived; otherwise upgrade
  # the on-PATH install in place -- best effort, since a system-managed Python
  # may refuse under PEP 668, in which case the installed version is kept. pip
  # only downloads a newer release when one exists.
  echo "Updating Semgrep..."
  if [ -x "/tmp/semgrep-venv/bin/pip" ]; then
    "/tmp/semgrep-venv/bin/pip" install --quiet --disable-pip-version-check --upgrade semgrep
  elif command -v python3 > /dev/null 2>&1; then
    python3 -m pip install --quiet --disable-pip-version-check --upgrade semgrep 2>/dev/null \
      || echo "WARN: could not auto-update Semgrep (externally-managed Python?); using the installed version." >&2
  fi
fi

# Collect optional arguments (project-provided rule exclusions and custom
# rules) into the positional parameters so they are passed safely without
# `eval`.
set --

if [ -f ".semgrepexcluderules" ]; then # check if you have rules to exclude
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      set -- "$@" --exclude-rule "$line"
    fi
  done < ".semgrepexcluderules"
fi

if [ -f ".semgrep.yaml" ]; then # check if you have custom rules to add
  set -- "$@" --config ".semgrep.yaml"
fi

semgrep \
  --metrics=off \
  --config "p/$SEMGREP_LANGUAGE" \
  --config "p/docker" \
  --config "p/dockerfile" \
  --config "p/secrets" \
  --config "p/owasp-top-ten" \
  --config "p/r2c-best-practices" \
  --enable-version-check --force-color \
  --error --json --output "$fileName" \
  "$@" || EXIT_CODE=$?

if ! ls "$REPORT_PATH"/*.json 1> /dev/null 2>&1; then
  echo "OK" > "$fileName"
fi

if [ "$ignoreFileExists" = false ]; then
  rm -f .semgrepignore
fi

exit "${EXIT_CODE:-0}"
