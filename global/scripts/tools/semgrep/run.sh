#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="semgrep" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

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
# The venv lives under ~/.local/share and its launcher is symlinked into
# ~/.local/bin (on PATH via the shared preamble) -- no root, and it persists so
# an already-present install is upgraded rather than reinstalled each run.
SEMGREP_VENV="$HOME/.local/share/semgrep-venv"

# Install when Semgrep is ABSENT **or when the version on PATH is not the
# pinned one**. Testing only for absence is not enough on a persistent or
# self-hosted runner: whatever Semgrep happened to be installed there first
# would keep running, so `SEMGREP_SPEC` would name a version the scan never
# used and the pin would be decorative. Reinstalling into our own venv and
# re-pointing the symlink is what makes the pin real -- `$HOME/.local/bin` is
# prepended to PATH by the shared preamble, so our copy wins over a
# system-wide one.
SEMGREP_PINNED_VERSION="${SEMGREP_SPEC##*==}"

semgrep_matches_pin() {
  _sg_current=$(semgrep --version 2>/dev/null | head -1 | tr -d '[:space:]')
  [ "$_sg_current" = "$SEMGREP_PINNED_VERSION" ]
}

if ! command -v semgrep > /dev/null 2>&1 || ! semgrep_matches_pin; then
  if ! command -v python3 > /dev/null 2>&1; then
    echo "ERROR: Semgrep requires Python 3 (it has no standalone binary release). Install python3 and re-run." >&2
    exit 1
  fi
  echo "Installing $SEMGREP_SPEC..."
  # Both steps are checked. An unchecked install is worse than a noisy one:
  # `python3 -m venv` fails on a distribution without the venv module, pip
  # fails on a missing wheel or a blocked index, and in either case the next
  # thing that speaks is the pin check below -- which would report a PATH
  # problem for what is really an install that never happened.
  if [ ! -x "$SEMGREP_VENV/bin/pip" ] && ! python3 -m venv "$SEMGREP_VENV"; then
    echo "ERROR: could not create the Semgrep virtualenv at $SEMGREP_VENV." >&2
    echo "       On Debian and Ubuntu this usually means the python3-venv package is absent." >&2
    exit 1
  fi
  # Output is captured rather than discarded with --quiet, so a failure can
  # still say why in pip's own words.
  if ! _sg_pip_log=$("$SEMGREP_VENV/bin/pip" install --disable-pip-version-check --only-binary :all: "$SEMGREP_SPEC" 2>&1); then
    echo "ERROR: pip could not install $SEMGREP_SPEC into $SEMGREP_VENV." >&2
    printf '%s\n' "$_sg_pip_log" >&2
    exit 1
  fi
  ln -sf "$SEMGREP_VENV/bin/semgrep" "$HOME/.local/bin/semgrep"

  if ! semgrep_matches_pin; then
    # Report what was OBSERVED rather than a presumed cause. This branch has
    # more than one explanation -- another copy earlier on PATH, a broken
    # install, a launcher that cannot run -- and naming only the first sends
    # the reader hunting through PATH for something that may not be there.
    # The resolved path separates them: a different path is a shadow, the
    # expected path with an unexpected version string is a broken install.
    echo "ERROR: Semgrep on PATH is not the pinned $SEMGREP_PINNED_VERSION after installation." >&2
    echo "       PATH resolves 'semgrep' to: $(command -v semgrep 2>/dev/null || echo '<not found>')" >&2
    echo "       Expected it to resolve to:  $HOME/.local/bin/semgrep" >&2
    echo "       Version it reported:        '$(semgrep --version 2>&1 | head -1)'" >&2
    exit 1
  fi
fi

# PINNED, and the "self-update to latest on every run" branch is gone with it.
# Semgrep is a gating SAST tool: each release adds and retunes rules, so an
# unpinned engine meant an unchanged commit could pass a scan on Monday and fail
# it on Tuesday, with nothing in the repository to explain the difference and no
# way to reproduce the earlier verdict. Bumping `SEMGREP_SPEC` makes that a
# reviewed change with a diff, which is what a rule change deserves.

# Collect optional arguments (rule configs, project-provided rule exclusions and
# custom rules) into the positional parameters so they are passed safely without
# `eval`.
set --

# semgrep_registry_pack_exists <config>
#
# True when the Semgrep Registry publishes the given config.
#
# Not every language Semgrep can PARSE has a rule pack published for it, and
# passing one that does not exist is fatal: `--config p/dart` fails the whole
# invocation, taking the language-agnostic packs (secrets, Dockerfile, OWASP)
# down with it. Dart is the concrete case -- `p/dart` is a 404 and the
# language-scoped `r/dart` returns an empty `rules: []` -- but the check is
# written generically so the next language in the same position needs no code.
#
# The fail-safe direction is deliberate: only an explicit 404 skips the pack.
# A timeout, a proxy error or any other inconclusive response keeps it, so a
# transient network problem can never quietly downgrade a scan to fewer rules
# while the job still reports success. If the registry really is unreachable,
# semgrep itself says so, in its own words.
semgrep_registry_pack_exists() {
  _sr_code="$(curl -sSL --proto '=https' --proto-redir '=https' -o /dev/null -w '%{http_code}' --max-time 15 "https://semgrep.dev/c/$1" 2>/dev/null)"
  [ "$_sr_code" != "404" ]
}

if [ -z "$SEMGREP_LANGUAGE" ] || [ "$SEMGREP_LANGUAGE" = "none" ]; then
  # An empty language used to compose the meaningless config `p/`, which fails
  # the run. Treat it as "language-agnostic packs only" instead.
  echo "No language pack requested; running the language-agnostic rule packs only."
elif semgrep_registry_pack_exists "p/$SEMGREP_LANGUAGE"; then
  set -- "$@" --config "p/$SEMGREP_LANGUAGE"
else
  echo "WARNING: the Semgrep Registry publishes no 'p/$SEMGREP_LANGUAGE' rule pack; skipping it." >&2
  echo "         The language-agnostic packs still run." >&2
fi

# Rules this repository ships for languages the registry does not cover. This is
# what keeps a Dart scan from being language-agnostic-only -- see
# `rules/dart.yaml` for why that file has to exist at all.
if [ -n "$SEMGREP_LANGUAGE" ]; then
  localRules="$SCRIPTS_DIR/global/scripts/tools/semgrep/rules/$SEMGREP_LANGUAGE.yaml"
  if [ -f "$localRules" ]; then
    echo "Adding the pipelines' own '$SEMGREP_LANGUAGE' rules: $localRules"
    set -- "$@" --config "$localRules"
  fi
fi

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
