# shellcheck shell=sh
#
# The workspace a CodeQL Go build may use. SOURCED, never executed: `run.sh` (`make codeql`, GitLab
# CI, Azure DevOps) calls it before `database create`, and the GitHub Actions `20-security/codeql`
# composite before `init`, so both builds run under the same GOWORK.
#
#   codeql_go_workspace <source root>
#
# Sets CODEQL_GOWORK to the GOWORK the build must run under -- the source root's own go.work, or
# `off` -- when the workspace `go` resolves from the source root lies outside it, and to the empty
# string when the build may run as it is. What it decided goes to stdout, as GitHub Actions reads
# its warning annotations.
#
# Why: the Go build joins the workspace `go` resolves where it runs: `$GOWORK` (or `go env -w
# GOWORK`), else the first go.work in that directory or in ANY directory above it -- the
# repository's parents included. CodeQL's Go autobuilder looks for go.work files under the source
# root only, so a checkout or worktree kept below a directory whose go.work does not list it is
# built as a plain module ("Found no go.work files in the workspace") while every `go` command of
# that build joins the outside workspace and loads nothing: `pattern ./...: directory prefix . does
# not contain modules listed in go.work or their selected dependencies`. The extractor recorded the
# go.mod alone, and the scan passed over a database without one line of Go.
#
# So the build uses a workspace only when the source root holds it. One resolved outside is set
# aside -- for the source root's own go.work, which only an explicit GOWORK can outrank, or with
# GOWORK=off when there is none -- and the modules build as in a clean checkout, which is what CI
# scans. A go.work inside the source root is the repository's own and is left to the autobuilder.
# The question is asked under GOTOOLCHAIN=local, so it downloads nothing an outside go.work asks
# for; without a `go` on PATH there is nothing to resolve, and the build itself reports the gap.
#
# A go.work below the source root goes unread under the override: the autobuilder builds such a
# workspace from that go.work's own directory, which GOWORK=off leaves outside any module (`build
# flag -mod=readonly only valid when using modules`), so none of its modules is extracted. That is
# said as a warning, naming each one. A temporary go.work using every module of the repository
# would build them, but it is one workspace for the whole repository: two modules sharing a module
# path -- example or fixture copies, a fork a `replace` points at -- fail every module in it
# (`module example appears multiple times in workspace`), where each builds on its own today.
codeql_go_workspace() {
  CODEQL_GOWORK=''
  _cgw_root="$1"
  command -v go > /dev/null 2>&1 || return 0
  _cgw_workspace="$(cd "$_cgw_root" && GOTOOLCHAIN=local go env GOWORK 2> /dev/null)" || _cgw_workspace=''
  case "$_cgw_workspace" in
    '' | off) return 0 ;;
  esac
  _cgw_root_dir="$(cd "$_cgw_root" && pwd -P)" || return 0
  _cgw_workspace_dir="$(cd "$_cgw_root" && cd "$(dirname "$_cgw_workspace")" 2> /dev/null && pwd -P)" || _cgw_workspace_dir=''
  case "$_cgw_workspace_dir/" in
    "$_cgw_root_dir"/*) return 0 ;;
  esac
  if [ -f "$_cgw_root/go.work" ]; then
    CODEQL_GOWORK="$_cgw_root/go.work"
  else
    CODEQL_GOWORK=off
  fi
  echo "The Go workspace $_cgw_workspace is outside the source root; building with GOWORK=$CODEQL_GOWORK, as a clean checkout would."
  [ "$CODEQL_GOWORK" = off ] || return 0
  _cgw_unread="$(cd "$_cgw_root" && find . -name go.work -not -path '*/vendor/*' -not -path './.git/*' 2> /dev/null \
    | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ -n "$_cgw_unread" ]; then
    _cgw_warning="GOWORK=off leaves the go.work below the source root unread ($_cgw_unread), so CodeQL extracts none of its modules; scan a checkout no outside go.work reaches to analyse them."
    echo "WARNING: $_cgw_warning"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      echo "::warning title=CodeQL::$_cgw_warning"
    fi
  fi
  return 0
}
