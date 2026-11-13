#!/usr/bin/env sh
#
# ansible-lint: the linter for Ansible playbooks, roles and collections.
#
# A LINTER, run by `make ansible-lint` -- which an Ansible project calls from its own `lint`
# target -- and never by `make sast`. Projects lint through this runner rather than through
# whatever `ansible-lint` a machine happens to have, so every one of them is held to the same
# pinned release.
#
# THE PIN IS WHAT RUNS. ansible-lint ships no binary -- it is a PyPI package -- so it is installed
# the way Checkov is: the release's universal wheel is downloaded by name and refused unless its
# SHA-256 matches the digest committed in `pinned-versions.sh`, then that file is installed
# binary-only into a virtualenv of its own, and the pin is checked against the metadata pip wrote
# (shared/venv-distribution.sh), never against `ansible-lint --version`. The lint runs that
# virtualenv's launcher by path, with the virtualenv's `bin` first on PATH: ansible-lint runs
# `ansible-playbook --syntax-check`, `ansible-config` and `ansible-galaxy` by name, and without it
# a developer's own Ansible -- `~/.local/bin`, which the shared preamble puts first, is a common
# home for one -- would answer in place of the ansible-core installed beside the pin.
#
# Two of ansible-lint's own habits would undo the pin, so both are switched off for the run. Once
# a day it rewrites the JSON schemas inside its installed package with whatever upstream publishes
# that day (`ANSIBLE_LINT_SKIP_SCHEMA_UPDATE=1`), and at the end of a run it looks up its latest
# release on GitHub (once a day) and prints the `pip` command that would replace the pinned one.
# It skips that lookup only offline or under pre-commit, so `PRE_COMMIT=1` is set for that alone:
# it is the one thing the variable changes in ansible-lint.
#
# NOT OFFLINE. `--offline` would also stop ansible-lint provisioning the project: the collection a
# `galaxy.yml` defines, whose playbooks name its roles by their fully qualified names, and the
# collections a `requirements.yml` or `galaxy.yml` declares. Offline, a collection's own playbooks
# fail `syntax-check` on roles that are right beside them. What it provisions is kept in `.ansible/`
# at the project root, which the shared ignore rules (`global/gitignore/common`) cover. A project
# that wants it offline says so in its own configuration (`offline: true`).
#
# THE PROJECT'S CONFIGURATION. It runs from the project root and hands ansible-lint the project's
# configuration file, the first of the names ansible-lint itself looks for, so the profile,
# `skip_list`, `warn_list` and `exclude_paths` are the project's. None is shipped here: without
# one, ansible-lint's own defaults apply.
#
# THE VERDICT is ansible-lint's exit code: 0 nothing to report, 2 violations. A warning (a rule in
# `warn_list`, an experimental rule) is reported but does not fail the lint -- that is the severity
# floor, and the project's configuration sets it (`strict: true` makes warnings fail too). Any
# other code means the lint itself did not complete, and is named.
#
# NOTHING TO LINT IS A SKIP. A project with no ansible-lint configuration, no `galaxy.yml`, no
# `playbooks/` or `roles/` directory, no role `tasks/main.yml` and no YAML play (a `hosts:` key at
# the top level of a list) installs nothing and gets an empty SARIF report.
#
# Report: `build/reports/ansible-lint/ansible-lint.sarif`.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="ansible-lint" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"
. "$SCRIPTS_DIR/global/scripts/shared/venv-distribution.sh"

# Under the working directory, as the other runners write it, unless REPORT_PATH is absolute.
case "$REPORT_PATH" in
  /*) sarifFile="$REPORT_PATH/ansible-lint.sarif" ;;
  *) sarifFile="$(pwd)/$REPORT_PATH/ansible-lint.sarif" ;;
esac

# The configuration files ansible-lint looks for, in its own order.
ANSIBLE_LINT_CONFIGS='.ansible-lint .ansible-lint.yml .ansible-lint.yaml .config/ansible-lint.yml .config/ansible-lint.yaml'

# ansible_content
#
# Prints the first sign that this project holds Ansible content, or nothing. Hidden directories
# (`.git/`, `.ansible/`, `.github/`), `node_modules/`, `vendor/` and the top-level `build/` -- the
# reports, and the collection link a project may keep there -- are not read.
ansible_content() {
  for _al_config in $ANSIBLE_LINT_CONFIGS; do
    if [ -f "$_al_config" ]; then
      printf '%s\n' "$_al_config"
      return 0
    fi
  done
  _al_found=$(find . \( -type d \( -name '.?*' -o -name node_modules -o -name vendor -o -path ./build \) -prune \) \
    -o \( -type f \( -name galaxy.yml -o -name galaxy.yaml -o -path '*/tasks/main.yml' -o -path '*/tasks/main.yaml' \) -print \) \
    -o \( -type d \( -name playbooks -o -name roles \) -print \) 2> /dev/null | head -n 1)
  if [ -z "$_al_found" ]; then
    # A play is an item of a top-level list: `- hosts:`, or `hosts:` under a `- name:`.
    _al_found=$(find . \( -type d \( -name '.?*' -o -name node_modules -o -name vendor -o -path ./build \) -prune \) \
      -o \( -type f \( -name '*.yml' -o -name '*.yaml' \) -exec grep -lE '^(- |  )hosts:' {} + \) 2> /dev/null | head -n 1)
  fi
  printf '%s\n' "$_al_found"
}

ANSIBLE_LINT_FOUND=$(ansible_content)
if [ -z "$ANSIBLE_LINT_FOUND" ]; then
  echo "No Ansible content found, skipping ansible-lint."
  cat > "$sarifFile" <<'EOF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "ansible-lint",
          "informationUri": "https://github.com/ansible/ansible-lint",
          "rules": []
        }
      },
      "results": []
    }
  ]
}
EOF
  echo "Empty report written to: $sarifFile"
  exit 0
fi
echo "Ansible content found ($ANSIBLE_LINT_FOUND)."

# The virtualenv persists under ~/.local/share, so a persistent runner installs once per pin.
ANSIBLE_LINT_VENV="$HOME/.local/share/ansible-lint-venv"

ansible_lint_matches_pin() {
  [ -x "$ANSIBLE_LINT_VENV/bin/ansible-lint" ] || return 1
  [ "$(venv_distribution_version "$ANSIBLE_LINT_VENV" ansible_lint)" = "$ANSIBLE_LINT_VERSION" ]
}

if ! ansible_lint_matches_pin; then
  if ! command -v python3 > /dev/null 2>&1; then
    echo "ERROR: ansible-lint needs Python 3 (it ships no binary). Install python3 and re-run." >&2
    exit 1
  fi
  if [ ! -x "$ANSIBLE_LINT_VENV/bin/pip" ] && ! python3 -m venv "$ANSIBLE_LINT_VENV"; then
    echo "ERROR: could not create the ansible-lint virtualenv at $ANSIBLE_LINT_VENV." >&2
    echo "       On Debian and Ubuntu this usually means the python3-venv package is absent." >&2
    exit 1
  fi
  ANSIBLE_LINT_WHEEL_SHA256=$(pinned_digest ANSIBLE_LINT "") || exit 1
  if ! _al_download_dir=$(mktemp -d); then
    echo "ERROR: could not create a directory to download ansible-lint into." >&2
    exit 1
  fi
  _al_wheel="$_al_download_dir/ansible_lint-$ANSIBLE_LINT_VERSION-py3-none-any.whl"
  echo "Installing ansible-lint $ANSIBLE_LINT_VERSION..."
  if ! download_verified \
    "https://files.pythonhosted.org/packages/py3/a/ansible-lint/ansible_lint-${ANSIBLE_LINT_VERSION}-py3-none-any.whl" \
    "$_al_wheel" \
    "$ANSIBLE_LINT_WHEEL_SHA256"; then
    rm -rf "$_al_download_dir"
    exit 1
  fi
  # Captured rather than silenced, so a failure still says why in pip's words.
  if ! _al_pip_log=$("$ANSIBLE_LINT_VENV/bin/pip" install --disable-pip-version-check --only-binary :all: "$_al_wheel" 2>&1); then
    rm -rf "$_al_download_dir"
    printf '%s\n' "$_al_pip_log" >&2
    echo "ERROR: the verified ansible-lint $ANSIBLE_LINT_VERSION wheel could not be installed into $ANSIBLE_LINT_VENV by pip." >&2
    exit 1
  fi
  rm -rf "$_al_download_dir"
  if ! ansible_lint_matches_pin; then
    echo "ERROR: the virtualenv at $ANSIBLE_LINT_VENV does not hold ansible-lint $ANSIBLE_LINT_VERSION after installation;" >&2
    echo "       it holds '$(venv_distribution_version "$ANSIBLE_LINT_VENV" ansible_lint)'." >&2
    exit 1
  fi
fi

# Collect the arguments in the positional parameters, so they pass without `eval`.
set --
for _al_config in $ANSIBLE_LINT_CONFIGS; do
  if [ -f "$_al_config" ]; then
    echo "Using the project's ansible-lint configuration: $_al_config"
    set -- "$@" --config-file "$_al_config"
    break
  fi
done

echo "Running ansible-lint $ANSIBLE_LINT_VERSION..."
PATH="$ANSIBLE_LINT_VENV/bin:$PATH" ANSIBLE_LINT_SKIP_SCHEMA_UPDATE=1 PRE_COMMIT=1 \
  "$ANSIBLE_LINT_VENV/bin/ansible-lint" "$@" --sarif-file "$sarifFile" || ANSIBLE_LINT_EXIT=$?

case "${ANSIBLE_LINT_EXIT:-0}" in
  0) echo "ansible-lint found nothing to report. Results written to: $sarifFile" ;;
  2) echo "ansible-lint found violations, listed above. Results written to: $sarifFile" >&2 ;;
  3) echo "ERROR: ansible-lint exited with code 3: its configuration is invalid." >&2 ;;
  4) echo "ERROR: ansible-lint exited with code 4: another ansible-lint held the lock on this project's .ansible/ for three minutes." >&2 ;;
  5) echo "ERROR: ansible-lint exited with code 5: it linted no file, though this project has Ansible content. Check exclude_paths." >&2 ;;
  *) echo "ERROR: ansible-lint exited with code $ANSIBLE_LINT_EXIT, which is neither a clean lint (0) nor violations (2): the lint did not complete." >&2 ;;
esac
exit "${ANSIBLE_LINT_EXIT:-0}"
