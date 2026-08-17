#!/usr/bin/env sh

# Shared helpers for the `50-deployment` provider scripts.
#
# This file is SOURCED, never executed, so it carries no `run.sh` name and no
# executable bit. Each provider's `run.sh` sources `cleanup.sh` first (which
# exports `REPORT_PATH` and puts `$HOME/.local/bin` on `PATH`) and then this
# file.
#
# The one rule every provider script here follows: A CREDENTIAL IS NEVER PASSED
# ON ARGV. Every CLI these scripts drive accepts its token through an
# environment variable (`VERCEL_TOKEN`, `NETLIFY_AUTH_TOKEN`,
# `CLOUDFLARE_API_TOKEN`, `FLY_API_TOKEN`), and the one provider without a CLI
# (Render) is driven with `curl --config -`, which reads the auth header from
# stdin. Argv is the wrong channel twice over: it is world-readable in `ps` for
# the lifetime of the process on a shared or self-hosted runner, and
# `deploy_run` below records the command line into the job's published artifact,
# so a token on argv would be exfiltrated into `command.txt` and kept for the
# artifact's retention period. This mirrors the reasoning behind
# `-DnvdApiKeyEnvironmentVariable` in the Dependency-Check runner
# (GHSA-qqhq-8r2c-c3f5): pass the NAME, never the VALUE.

# Pinned tool versions and the integrity-checked downloader, sourced once here
# so every provider script gets them from the single `common.sh` it already
# sources. Doing it per-provider would be five chances to forget one, and the
# provider that forgot would look identical to the ones that did not.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

# deploy_require_env <VAR_NAME> <hint>
#
# Fail with an actionable message when a required credential or identifier is
# missing. These scripts run under POSIX `sh` without `set -e`, so an unset
# token would otherwise reach the CLI and surface as that vendor's own
# authentication error -- which names the vendor's internals rather than the
# pipeline variable the consumer actually has to set.
deploy_require_env() {
  _de_name="$1"
  _de_hint="$2"
  eval "_de_value=\${$_de_name:-}"
  if [ -z "$_de_value" ]; then
    echo "ERROR: $_de_name is not set. $_de_hint" >&2
    exit 1
  fi
  unset _de_value

  return 0
}

# deploy_npm_cli <binary> <npm-package>
#
# Install an npm-published CLI into `$HOME/.local` when the binary is absent.
# `--prefix "$HOME/.local"` is what keeps this root-free: a plain `npm install
# -g` targets a root-owned prefix and fails (or silently needs `sudo`) on
# GitHub-hosted, GitLab and Azure DevOps agents alike, while `$HOME/.local/bin`
# is already on `PATH` via the `cleanup.sh` preamble every one of these scripts
# sources.
#
# The package argument is a full npm SPEC (`vercel@59`), not a bare name.
#
# These were previously installed unversioned, which resolved to `latest` on
# every run: the client holding the production deploy credential was chosen by
# whatever npm had published that morning, and a deploy could not say which
# client shipped it. The counter-argument for leaving them floating is real --
# these talk to a hosted API the vendor versions on their side, and freezing an
# exact build would break every consumer the day the vendor retires that API
# version -- so the pin is to the MAJOR this repository has verified. npm still
# resolves the newest release inside it, and `pinned-versions.sh` documents how
# a consumer needing a byte-exact client sets an exact version instead.
#
# `--ignore-scripts` is the other half. `npm install` runs arbitrary
# `postinstall` scripts from the package AND its whole transitive tree, as the
# CI user, with the deploy token already in the environment -- the standard
# npm-supply-chain execution path. None of these three CLIs needs one to work.
deploy_npm_cli() {
  _dn_binary="$1"
  _dn_package="$2"

  if command -v "$_dn_binary" > /dev/null 2>&1; then
    return 0
  fi

  # A dry run resolves and records the command line without deploying, so the
  # CLI is never invoked and installing it would be pure cost -- a ~100 MB npm
  # download per provider. Skipping it is also what lets the validation harness
  # exercise all five providers offline, with no Node.js toolchain present.
  if deploy_is_dry_run; then
    echo "DRY RUN: skipping installation of '$_dn_package'."
    return 0
  fi

  if ! command -v npm > /dev/null 2>&1; then
    echo "ERROR: '$_dn_binary' is not installed and npm is unavailable to install '$_dn_package'." >&2
    echo "Add a Node.js setup step to the job (e.g. actions/setup-node, a node image, or NodeTool@0)." >&2
    exit 1
  fi

  echo "Installing $_dn_package..."
  if ! npm install --global --no-fund --no-audit --ignore-scripts --prefix "$HOME/.local" "$_dn_package"; then
    echo "ERROR: failed to install '$_dn_package' via npm." >&2
    exit 1
  fi

  if ! command -v "$_dn_binary" > /dev/null 2>&1; then
    echo "ERROR: installing '$_dn_package' did not produce a runnable '$_dn_binary' binary." >&2
    exit 1
  fi
}

# deploy_is_dry_run
#
# True when DEPLOY_DRY_RUN holds a truthy value, compared case-insensitively.
#
# The case folding is not cosmetic. Azure DevOps stringifies a `boolean`
# template parameter as `True` / `False` (PascalCase), so a strict `= "true"`
# test silently turned a REQUESTED DRY RUN INTO A REAL DEPLOY on that platform
# alone -- the most dangerous possible direction for this particular flag to
# fail in, and invisible to a test suite that only ever drives the scripts
# directly. The Azure templates now pass `lower(...)` as well, but accepting
# the platform's own spelling here is the belt to that braces: it means a
# future template (or a consumer exporting the variable by hand) cannot
# reintroduce the same failure by forgetting the wrapper.
deploy_is_dry_run() {
  deploy_is_truthy "${DEPLOY_DRY_RUN:-false}"
}

# deploy_is_truthy <value>
#
# The case-folding comparison itself, for every other flag this family reads
# from a platform template. `DEPLOY_DRY_RUN` is the dangerous one but not the
# only one: `VERCEL_COMMERCIAL` is also declared `boolean` in the Azure
# template, so a strict comparison meant the Hobby-tier licence warning could
# never fire on Azure -- silently removing the one guard against a monetised
# project running on a non-commercial plan.
deploy_is_truthy() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# deploy_run <command> [args...]
#
# Record the resolved command line into the job's report directory, then run it
# -- or, when `DEPLOY_DRY_RUN=true`, stop at the recording. The dry run is what
# makes this whole family testable in `make test`: the validation harness can
# assert on the exact argv each provider builds from a given set of inputs
# without credentials, a network, or a real deploy. It is the same technique
# `.github/tests/test-dependency-check.sh` uses against a stub build tool.
#
# Writing `command.txt` unconditionally (rather than only on the dry-run path)
# also means a failed real deploy leaves behind the exact invocation that
# failed, which is the first thing anyone debugging a red deploy job asks for.
deploy_run() {
  deploy_note_command "$*"

  if deploy_is_dry_run; then
    echo "DRY RUN (no deploy performed): $*"
    return 0
  fi

  echo "Running: $*"
  "$@"
}

# deploy_note_command <text>
#
# Record a command line WITHOUT executing it, and report whether execution
# should proceed (0 = go, 1 = dry run, stop). Providers driven through an HTTP
# API rather than a CLI need this split: their real invocation feeds a
# credential to `curl` on stdin, so the thing that is safe to record and the
# thing that is safe to execute are not the same string, and routing them
# through `deploy_run` would either execute the redacted placeholder or publish
# the secret.
deploy_note_command() {
  _dc_command="$1"

  printf '%s\n' "$_dc_command" > "$REPORT_PATH/command.txt"

  if deploy_is_dry_run; then
    echo "DRY RUN (no deploy performed): $_dc_command"
    return 1
  fi

  return 0
}

# deploy_record <provider> <target>
#
# Write a small JSON receipt describing what was deployed. Every platform in
# this repository publishes `build/reports/` as a job artifact, so this gives
# all three the same machine-readable answer to "what did this job actually
# ship, and was it a real deploy or a dry run?" without each one inventing its
# own log-scraping convention.
deploy_record() {
  _dr_provider="$1"
  _dr_target="$2"

  # Normalised through `deploy_is_dry_run` rather than interpolated raw. The
  # raw value is whatever the platform handed over, and JSON accepts exactly
  # two spellings of a boolean: Azure DevOps' `True` / `False` produced a
  # receipt that no parser would read, on EVERY Azure deploy including ordinary
  # production runs that never asked for a dry run. Emitting the canonical
  # literal means the file is valid whatever the caller wrote.
  if deploy_is_dry_run; then
    _dr_dry="true"
  else
    _dr_dry="false"
  fi

  cat > "$REPORT_PATH/deployment.json" <<EOF
{
  "provider": "$_dr_provider",
  "target": "$_dr_target",
  "dry_run": $_dr_dry,
  "environment": "${DEPLOY_ENVIRONMENT:-production}"
}
EOF
  echo "Deployment record written to: $REPORT_PATH/deployment.json"

  return 0
}
