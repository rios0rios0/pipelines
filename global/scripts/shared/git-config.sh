#!/usr/bin/env sh
# shellcheck shell=sh
#
# Git settings a shared script needs for its own run, kept out of a developer's global configuration.
# SOURCED, never executed -- it carries no `run.sh` name and no executable bit.
#
# These scripts run on two kinds of machine. On a CI runner the global git configuration belongs to
# the job: the runner is thrown away afterwards, and a later step of the same job -- a process of its
# own -- may need what an earlier one configured, so a setting written there is what the step
# meant. On a developer's machine `~/.gitconfig` is the developer's own and outlives the run: the
# gitleaks runner used to append the project to its `safe.directory` on every scan, and a project's
# `config.sh` sourced by the CodeQL runner wrote a URL rewrite carrying a token, or an
# `Authorization` header with an empty one, that every later `git` on the machine then sent. So on
# a developer's machine a setting reaches git through the environment of the run that needs it
# (`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>`, `GIT_CONFIG_VALUE_<n>`, git 2.31+), which ends with the
# run and is never written to disk.

# git_config_on_ci: 0 on a CI runner. GitHub Actions and GitLab CI export CI on every job, Azure
# DevOps exports TF_BUILD; anything else is a developer's machine, as the CodeQL runner decides it.
git_config_on_ci() {
  [ -n "${CI:-}" ] || [ -n "${TF_BUILD:-}" ]
}

# git_config_env <key> <value>: hands git one setting through the environment, for this process
# and every process it starts, and writes nothing to disk. The pairs already exported -- by a
# project's `config.sh`, or by an earlier call -- are kept, and a pair already among them is not
# added twice, so a script that asks for the same setting on every run of a loop adds it once.
git_config_env() {
  _gce_count="${GIT_CONFIG_COUNT:-0}"
  case "$_gce_count" in
    '' | *[!0-9]*) _gce_count=0 ;;
    *) ;;
  esac
  _gce_index=0
  _gce_key=''
  _gce_value=''
  while [ "$_gce_index" -lt "$_gce_count" ]; do
    # The index is a number this loop produced, so the name `eval` reads is never anyone's input.
    eval "_gce_key=\${GIT_CONFIG_KEY_${_gce_index}:-}"
    eval "_gce_value=\${GIT_CONFIG_VALUE_${_gce_index}:-}"
    if [ "$_gce_key" = "$1" ] && [ "$_gce_value" = "$2" ]; then
      unset _gce_count _gce_index _gce_key _gce_value
      return 0
    fi
    _gce_index=$((_gce_index + 1))
  done
  export "GIT_CONFIG_KEY_${_gce_count}=$1" "GIT_CONFIG_VALUE_${_gce_count}=$2"
  export GIT_CONFIG_COUNT="$((_gce_count + 1))"
  unset _gce_count _gce_index _gce_key _gce_value
  return 0
}

# git_trust_directory <dir>: lets git work in <dir> when its owner is not the user running git
# (`safe.directory`; git refuses such a repository with `detected dubious ownership`). On a CI
# runner the directory is added to the global configuration, once: a job's checkout or toolchain
# is routinely owned by another user there, and a later step may run git in it. Anywhere else it
# is handed to this process and its children through the environment, and the developer's global
# configuration is left as it was.
git_trust_directory() {
  if git_config_on_ci; then
    # `--add` appends a line on every call, so a runner that keeps its configuration between jobs
    # would grow it by one entry per run: add the directory only when it is not trusted yet.
    if ! git config --global --get-all safe.directory 2> /dev/null | grep -Fqx -- "$1"; then
      git config --global --add safe.directory "$1" > /dev/null 2>&1 || true
    fi
  else
    git_config_env safe.directory "$1"
  fi
  return 0
}

# git_isolate_global_config <dir>: from here on, `git config --global` in this process and its
# children writes into `<dir>/gitconfig`, which goes when <dir> goes, instead of the developer's
# own file. That file includes the global configuration git read until now -- `GIT_CONFIG_GLOBAL`
# when it is set, otherwise `$XDG_CONFIG_HOME/git/config` and `~/.gitconfig`, in git's own order --
# so a credential helper, an identity or a rewrite the developer configured still applies. It is
# what a runner calls before it sources a project's `config.sh` on a developer's machine, so a
# `config.sh` that still runs `git config --global` configures the run that sourced it and nothing
# after it.
git_isolate_global_config() {
  _gig_file="$1/gitconfig"
  {
    printf '[include]\n'
    if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
      git_config_quoted_path "$GIT_CONFIG_GLOBAL"
    else
      git_config_quoted_path "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
      git_config_quoted_path "$HOME/.gitconfig"
    fi
  } > "$_gig_file" || {
    unset _gig_file
    return 1
  }
  GIT_CONFIG_GLOBAL="$_gig_file"
  export GIT_CONFIG_GLOBAL
  unset _gig_file
  return 0
}

# git_config_quoted_path <path>: one `path = "<path>"` line of an `[include]` section. The value is
# quoted, with its backslashes and double quotes escaped, so a `#` or `;` in a home directory is
# not read as the start of a comment.
git_config_quoted_path() {
  printf '\tpath = "%s"\n' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
