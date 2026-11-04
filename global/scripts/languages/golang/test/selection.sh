# shellcheck shell=sh
# shellcheck disable=SC2034  # the GO_TEST_SELECTION_* results are read by run.sh, which sources this file
# Sourced by run.sh, never executed: the test selection of the Go runner.
#
# GO_TEST_SELECTION picks what the two test phases run:
#
#   all       (the default) every package, exactly as before this file existed;
#   affected  only the packages a change can reach: the packages whose files the
#             change touched, and every package whose dependency closure, test
#             imports included, contains one of them.
#
# `affected` compares HEAD with the merge base of HEAD and GO_TEST_SELECTION_BASE
# (a ref or a commit, e.g. `origin/main`); on GitLab CI a merge request's
# CI_MERGE_REQUEST_DIFF_BASE_SHA is taken when the variable is unset. It falls back
# to running everything -- and says why -- whenever a change could reach every
# package or the comparison cannot be made:
#
#   - no base, no git checkout, or no merge base (a shallow clone that does not
#     reach it, or a base that was never fetched);
#   - go.mod, go.sum, go.work, go.work.sum or anything under vendor/ (the module's
#     own definition: every package builds against it);
#   - a Makefile or *.mk, or CI configuration (.github/, .gitlab/, .gitlab-ci.yml,
#     azure-pipelines*.yml, .azure-pipelines/, .ci/): what builds and runs the tests;
#   - any other file outside every Go package, which a build or a test may read
#     without the module saying so (a fixture at the repository root, a file a
#     test opens by a relative path).
#
# A changed file belongs to a package when `go list` names it among that
# package's files -- Go sources of every kind, test files, and the files its
# //go:embed patterns match (migrations, templates) -- under the unit or the
# integration tags; when it sits in a package's directory (a deleted file, one
# excluded by a build constraint); or when it sits under a package's testdata/.
# Markdown, changelog fragments (.changes/), licence files and git's own dotfiles
# outside those are documentation: they select nothing, unless a test names one
# in a string literal (its repository or module path, or its bare name) -- a test
# that pins a document to the code -- in which case it selects that test's
# package. A change made only of documentation no test names selects no package
# at all, and both phases pass with nothing to run.
#
# The dependency closure is read from `go list -test`, whose `Deps` is the
# transitive closure of a package's imports and, for its test variants, of its
# tests' imports as well. It is read once per tag set (the unit phase's
# `test,unit` and the integration phase's `integration`), because a build tag
# can add an import.
#
# A selection is a pull-request tool. It can miss a test that reads a file the
# module does not declare and that the rules above take for documentation, so
# the default branch should keep running everything.

# go_test_selection_prepare decides between `all` and `affected`. It sets
#   GO_TEST_SELECTION_EFFECTIVE  `all` or `affected`
#   GO_TEST_SELECTION_REASON     why `all` was chosen
#   GO_TEST_SELECTION_CHANGED    the changed packages, one import path per line
# and returns non-zero only on a GO_TEST_SELECTION it does not know.
go_test_selection_prepare() {
  GO_TEST_SELECTION_EFFECTIVE=all
  GO_TEST_SELECTION_REASON=""
  GO_TEST_SELECTION_CHANGED=""

  case "${GO_TEST_SELECTION:-all}" in
    '' | all)
      GO_TEST_SELECTION_REASON="test selection is 'all'"
      return 0
      ;;
    affected) ;;
    *)
      echo "GO_TEST_SELECTION must be 'all' or 'affected', got '${GO_TEST_SELECTION}'" >&2
      return 1
      ;;
  esac

  selection_base="${GO_TEST_SELECTION_BASE:-${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}}"
  if [ -z "$selection_base" ]; then
    GO_TEST_SELECTION_REASON="no base to compare with (GO_TEST_SELECTION_BASE is empty)"
    return 0
  fi
  if ! selection_top="$(git rev-parse --show-toplevel 2> /dev/null)"; then
    GO_TEST_SELECTION_REASON="not a git checkout"
    return 0
  fi
  if ! selection_merge_base="$(git merge-base "$selection_base" HEAD 2> /dev/null)"; then
    GO_TEST_SELECTION_REASON="no merge base between '${selection_base}' and HEAD (a shallow clone that does not reach it, or a base that was never fetched)"
    return 0
  fi
  if ! selection_files="$(git diff --name-only --no-renames "$selection_merge_base" HEAD)"; then
    GO_TEST_SELECTION_REASON="git diff against the merge base failed"
    return 0
  fi
  echo "Test selection: comparing HEAD with ${selection_base} (merge base ${selection_merge_base})"

  # One line per package directory (D) and per file the package reads (F), under
  # both tag sets and over the whole module, so a helper package outside the
  # tested directories still maps. Tab-separated: a path may hold a space.
  # shellcheck disable=SC2016  # a Go template, not a shell expansion
  selection_template='{{$p := .ImportPath}}{{$d := .Dir}}D	{{$p}}	{{$d}}
{{range .GoFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .CgoFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .CFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .CXXFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .HFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .SFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .SysoFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .IgnoredGoFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .IgnoredOtherFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .TestGoFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .XTestGoFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .EmbedFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .TestEmbedFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}{{range .XTestEmbedFiles}}F	{{$p}}	{{$d}}/{{.}}
{{end}}'

  # From the physical directory, as git names the top level: under a symlinked
  # path the two would otherwise spell one file two ways.
  selection_listing="$(
    (cd -P . && go list -e -tags test,unit -f "$selection_template" ./...)
    (cd -P . && go list -e -tags integration -f "$selection_template" ./...)
  )"

  selection_verdict="$(
    {
      printf '%s\n' "$selection_listing"
      printf '%s\n' "$selection_files" | while IFS= read -r selection_file; do
        [ -n "$selection_file" ] && printf 'C\t%s\t%s/%s\n' "$selection_file" "$selection_top" "$selection_file"
      done
    } | awk -F '\t' '
      function dirname(path) { sub(/\/[^\/]*$/, "", path); return path }
      function base(path) { sub(/^.*\//, "", path); return path }
      $1 == "D" { dirs[$3] = $2; next }
      $1 == "F" { files[$3] = $2; next }
      $1 != "C" { next }
      {
        rel = $2; abs = $3; name = base(rel)
        if (name ~ /^(go\.mod|go\.sum|go\.work|go\.work\.sum)$/ || rel ~ /(^|\/)vendor\//) {
          print "ALL\t" rel " changes the module definition"; exit
        }
        if (name ~ /^(Makefile|GNUmakefile|makefile)$/ || name ~ /\.mk$/) {
          print "ALL\t" rel " changes how the build runs"; exit
        }
        if (rel ~ /^\.(github|gitlab|azure-pipelines|ci)\// || name == ".gitlab-ci.yml" ||
            name ~ /^azure-pipelines.*\.ya?ml$/) {
          print "ALL\t" rel " changes the CI configuration"; exit
        }
        if (abs in files) { print "P\t" files[abs]; next }
        if (name ~ /\.(md|markdown)$/ || rel ~ /^\.changes\// ||
            name ~ /^(LICENSE|LICENCE|COPYING|NOTICE)/ ||
            name ~ /^\.(gitignore|gitattributes|mailmap)$/) {
          print "I\t" rel; next
        }
        if (dirname(abs) in dirs) { print "P\t" dirs[dirname(abs)]; next }
        if (abs ~ /\/testdata\//) {
          owner = abs; sub(/\/testdata\/.*$/, "", owner)
          if (owner in dirs) { print "P\t" dirs[owner]; next }
        }
        print "ALL\t" rel " is outside every Go package, and a build or a test may read it"; exit
      }
    '
  )"

  case "$selection_verdict" in
    ALL* | *"
ALL"*)
      GO_TEST_SELECTION_REASON="$(printf '%s\n' "$selection_verdict" | awk -F '\t' '$1 == "ALL" { print $2; exit }')"
      return 0
      ;;
  esac

  selection_read="$(go_test_selection_documents_read "$selection_verdict")"
  GO_TEST_SELECTION_CHANGED="$(
    {
      printf '%s\n' "$selection_verdict"
      printf '%s\n' "$selection_read"
    } | awk -F '\t' '$1 == "P" { print $2 }' | sort -u
  )"
  GO_TEST_SELECTION_EFFECTIVE=affected
  return 0
}

# go_test_selection_documents_read <verdict> prints a `P<TAB>package` line for each
# package whose tests name a changed document, and logs what it found.
#
# Documentation selects nothing, except where a test pins it to the code: a test
# that checks a runbook still matches a repository, or that the README declares
# what a constant holds. Such a test reads the file by a string literal -- its
# path from the repository's top, from the module's, or its bare name -- so a
# changed document selects the packages of the test files that spell one of those
# between double quotes. A common name (`README.md`) can select a test that
# reads another file of that name; that costs a few extra packages, never a
# missed test. Reads `selection_listing`, `selection_top` and their siblings
# from go_test_selection_prepare.
go_test_selection_documents_read() {
  selection_prefix="$(git rev-parse --show-prefix 2> /dev/null)"
  selection_here="$(pwd -P)"
  printf '%s\n' "$1" | awk -F '\t' '$1 == "I" { print $2 }' | while IFS= read -r selection_document; do
    [ -n "$selection_document" ] || continue
    selection_name="${selection_document##*/}"
    selection_module_path="${selection_document#"$selection_prefix"}"
    selection_tests="$(git grep -l -F -e "\"${selection_document}\"" -e "\"${selection_module_path}\"" \
      -e "\"${selection_name}\"" -- '*_test.go' 2> /dev/null || true)"
    selection_packages="$(
      {
        printf '%s\n' "$selection_listing"
        printf '%s\n' "$selection_tests" | while IFS= read -r selection_test; do
          [ -n "$selection_test" ] && printf 'T\t%s/%s\n' "$selection_here" "$selection_test"
        done
      } | awk -F '\t' '
        $1 == "F" { files[$3] = $2; next }
        $1 == "T" && ($2 in files) { print files[$2] }
      ' | sort -u
    )"
    if [ -z "$selection_packages" ]; then
      echo "  not code, selects nothing: ${selection_document}" >&2
    else
      echo "  read by tests, selects their packages: ${selection_document} -> $(printf '%s\n' "$selection_packages" | tr '\n' ' ' | sed 's/ $//')" >&2
      printf '%s\n' "$selection_packages" | sed 's/^/P\t/'
    fi
  done
}

# go_test_selection_affected <tags> <patterns...> prints, one per line, the packages
# among <patterns> that a change to GO_TEST_SELECTION_CHANGED can reach under <tags>:
# the changed packages themselves and every package whose closure -- its own
# imports, or its tests' -- holds one of them.
go_test_selection_affected() {
  selection_tags="$1"
  shift
  [ -n "$GO_TEST_SELECTION_CHANGED" ] || return 0
  # Deps is joined on commas: a test variant's import path holds a space
  # ("p [p.test]"), an import path never holds a comma.
  # shellcheck disable=SC2016  # a Go template, not a shell expansion
  go list -e -test -tags "$selection_tags" \
    -f '{{if .ForTest}}{{.ForTest}}{{else}}{{.ImportPath}}{{end}}	{{.ImportPath}}	{{join .Deps ","}}' "$@" |
    SELECTION_CHANGED="$GO_TEST_SELECTION_CHANGED" awk -F '\t' '
      function strip(path) { sub(/ \[.*$/, "", path); return path }
      BEGIN {
        total = split(ENVIRON["SELECTION_CHANGED"], list, "\n")
        for (i = 1; i <= total; i++) if (list[i] != "") changed[list[i]] = 1
      }
      {
        owner = $1; self = $2
        # A real package: no test-variant suffix, not a generated test main.
        if (self !~ / \[/ && self !~ /\.test$/) packages[self] = 1
        sub(/\.test$/, "", owner)
        if (strip(self) in changed || owner in changed) { hit[owner] = 1; next }
        total = split($3, deps, ",")
        for (i = 1; i <= total; i++) if (strip(deps[i]) in changed) { hit[owner] = 1; break }
      }
      END { for (p in hit) if (p in packages) print p }
    ' | sort
}
