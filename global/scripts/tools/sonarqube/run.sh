#!/usr/bin/env sh
set -e

# Normalize a candidate SonarQube project key:
# - Replace whitespace and '/' with '_'
# - Replace any remaining unsupported characters with '_'
normalize_sonar_key() {
  printf '%s' "$1" | tr '[:space:]/' '_' | sed 's/[^A-Za-z0-9._:-]/_/g'
}

# Succeed when sonar-project.properties already defines the given key. The key
# is matched whole -- the `=` has to follow it directly -- so `sonar.tests` does
# not match `sonar.tests.foo` and `sonar.issue.ignore.multicriteria` does not
# match its own `.e1.ruleKey` entries.
has_sonar_property() {
  grep -Eq "^[[:space:]]*$(printf '%s' "$1" | sed 's/\./\\./g')[[:space:]]*=" sonar-project.properties 2>/dev/null
}

# Append `key=value` to sonar-project.properties unless the repository already
# defines the key: the same "only if absent" contract as projectKey and
# projectName, so declaring a key in the file is how a repository overrides
# any default derived here.
set_default_sonar_property() {
  if has_sonar_property "$1"; then
    echo "Keeping $1 from sonar-project.properties"
  else
    printf '%s=%s\n' "$1" "$2" >> sonar-project.properties
    echo "Auto-derived $1=$2"
  fi
}

# Auto-derive sonar.projectKey if not already in properties file
if ! grep -Eq '^[[:space:]]*sonar\.projectKey[[:space:]]*=' sonar-project.properties 2>/dev/null; then
  key=""
  if [ -n "${SONAR_PROJECT_KEY:-}" ]; then
    key="$SONAR_PROJECT_KEY"
  elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    key=$(normalize_sonar_key "$GITHUB_REPOSITORY")
  elif [ -n "${SYSTEM_TEAMPROJECT:-}" ] && [ -n "${BUILD_REPOSITORY_NAME:-}" ]; then
    key=$(normalize_sonar_key "${SYSTEM_TEAMPROJECT}_${BUILD_REPOSITORY_NAME}")
  elif [ -n "${CI_PROJECT_PATH:-}" ]; then
    key=$(normalize_sonar_key "$CI_PROJECT_PATH")
  fi
  if [ -n "$key" ]; then
    echo "sonar.projectKey=$key" >> sonar-project.properties
    echo "Auto-derived sonar.projectKey=$key"
  fi
fi

# Auto-derive sonar.projectName if not already in properties file
if ! grep -Eq '^[[:space:]]*sonar\.projectName[[:space:]]*=' sonar-project.properties 2>/dev/null; then
  name=""
  if [ -n "${SONAR_PROJECT_NAME:-}" ]; then
    name="$SONAR_PROJECT_NAME"
  elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    name="${GITHUB_REPOSITORY#*/}"
  elif [ -n "${BUILD_REPOSITORY_NAME:-}" ]; then
    if [ -n "${SYSTEM_TEAMPROJECT:-}" ]; then
      name="${SYSTEM_TEAMPROJECT}/${BUILD_REPOSITORY_NAME}"
    else
      name="$BUILD_REPOSITORY_NAME"
    fi
  elif [ -n "${CI_PROJECT_NAME:-}" ]; then
    name="$CI_PROJECT_NAME"
  fi
  if [ -n "$name" ]; then
    echo "sonar.projectName=$name" >> sonar-project.properties
    echo "Auto-derived sonar.projectName=$name"
  fi
fi

version=$(git describe --tags --abbrev=0) || true
if [ -z "$version" ]; then version="latest"; echo "No version tag found in the repository, setting version to $version"; fi
echo "sonar.projectVersion=$version" >> sonar-project.properties
echo "Updated sonar.projectVersion to $version"

# Directories a coverage report may sit in, repository root first. A project that
# does not live at the root (`working_directory` on the reusable workflows) writes
# its coverage beside its OWN manifest and the artifact is unpacked back there, so
# every pattern below has to be tried under that directory too. Searching only the
# root would read a subfolder project as "no coverage at all" -- and the block
# further down does not merely skip in that case, it appends EMPTY
# `sonar.*.reportPaths` values that override the ones the repository set for
# itself, silently reporting 0% coverage on new code.
#
# The two directories are never joined into one string: a `working_directory` with
# a space in it would word-split back into two nonexistent paths and drop the
# consumer straight back into the clobbering branch below, which is precisely the
# failure this block exists to prevent. Each search is a function called once per
# directory instead, so the value stays quoted everywhere it is a path and is
# unquoted only where a glob has to expand.
SONAR_PROJECT_DIR=${SONAR_PROJECT_DIR:-.}
SONAR_PROJECT_DIR=${SONAR_PROJECT_DIR%/}
[ -n "$SONAR_PROJECT_DIR" ] || SONAR_PROJECT_DIR=.
SONAR_PROJECT_DIR_IS_SEPARATE=false
if [ "$SONAR_PROJECT_DIR" != "." ] && [ -d "$SONAR_PROJECT_DIR" ]; then
  SONAR_PROJECT_DIR_IS_SEPARATE=true
  echo "Looking for coverage under the repository root and $SONAR_PROJECT_DIR"
fi

# Succeed when $1 holds a coverage report in any of the shapes the test stages of
# this repository produce.
coverage_present_in() {
  for pattern in \
    "coverage.out" \
    "coverage.txt" \
    "coverage/*.txt" \
    "coverage/*.xml" \
    "coverage/*.json" \
    "coverage/*.lcov" \
    "coverage/*.info" \
    "build/reports/coverage*" \
    "build/reports/cobertura.xml" \
    "build/reports/jacoco/test/jacocoTestReport.xml" \
    "target/site/jacoco/jacoco.xml" \
    "TestResults/*.xml" \
    "TestResults/Cobertura.xml"; do
    # shellcheck disable=SC2086
    if ls "$1"/$pattern 1>/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# Print the first Go coverage profile under $1, relative to the repository root
# and without a `./` prefix, or nothing when there is none.
#
# The `for` list itself performs the pathname expansion, so each match arrives as
# one word even when it contains a space, and a pattern that matches nothing
# arrives literally and fails `[ -f ]`. Re-splitting it in a nested loop would
# undo exactly that: `my api/coverage.out` would become `my` and `api/coverage.out`.
find_go_report() {
  for _cov_file in "$1"/coverage.out "$1"/coverage.txt "$1"/coverage/coverage.out \
    "$1"/coverage/coverage.txt "$1"/coverage/*.txt "$1"/coverage/*.out; do
    [ -f "$_cov_file" ] || continue
    printf '%s\n' "${_cov_file#./}"
    return 0
  done
  return 1
}

# The same, for the two places Gradle and Maven put a JaCoCo XML report.
find_jacoco_report() {
  for _cov_file in "$1"/build/reports/jacoco/test/jacocoTestReport.xml \
    "$1"/target/site/jacoco/jacoco.xml; do
    if [ -f "$_cov_file" ]; then
      printf '%s\n' "${_cov_file#./}"
      return 0
    fi
  done
  return 1
}

# Check if coverage files exist. If no coverage was produced by the test stage,
# override coverage report paths to avoid sonar-scanner failures when the project's
# sonar-project.properties references files that don't exist.
COVERAGE_FOUND=false
if coverage_present_in .; then
  COVERAGE_FOUND=true
elif [ "$SONAR_PROJECT_DIR_IS_SEPARATE" = "true" ] && coverage_present_in "$SONAR_PROJECT_DIR"; then
  COVERAGE_FOUND=true
fi

if [ "$COVERAGE_FOUND" = "false" ]; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") - No coverage files found. Running SonarQube without coverage data."
  # Remove any coverage-related properties so sonar-scanner doesn't fail
  # looking for files that don't exist. An empty value disables the property.
  {
    echo "sonar.coverage.jacoco.xmlReportPaths="
    echo "sonar.javascript.lcov.reportPaths="
    echo "sonar.python.coverage.reportPaths="
    echo "sonar.go.coverage.reportPaths="
    echo "sonar.cs.opencover.reportsPaths="
    echo "sonar.cs.dotcover.reportsPaths="
    echo "sonar.cs.vscoveragexml.reportsPaths="
  } >> sonar-project.properties
  echo "Cleared coverage report path properties in sonar-project.properties."
else
  # Root first, then the project, matching the detection above. The `./` a root
  # match picks up is stripped so the derived value keeps the shape it had before
  # a project directory was ever searched.
  # `|| true` because `set -e` would exit on the function's "not found" status.
  GO_REPORT_PATH=$(find_go_report .) || true
  if [ -z "$GO_REPORT_PATH" ] && [ "$SONAR_PROJECT_DIR_IS_SEPARATE" = "true" ]; then
    GO_REPORT_PATH=$(find_go_report "$SONAR_PROJECT_DIR") || true
  fi
  if [ -n "$GO_REPORT_PATH" ]; then
    echo "sonar.go.coverage.reportPaths=$GO_REPORT_PATH" >> sonar-project.properties
  fi

  # Auto-detect JaCoCo coverage reports (Gradle and Maven)
  JACOCO_REPORT_PATH=$(find_jacoco_report .) || true
  if [ -z "$JACOCO_REPORT_PATH" ] && [ "$SONAR_PROJECT_DIR_IS_SEPARATE" = "true" ]; then
    JACOCO_REPORT_PATH=$(find_jacoco_report "$SONAR_PROJECT_DIR") || true
  fi
  if [ -n "$JACOCO_REPORT_PATH" ]; then
    echo "sonar.coverage.jacoco.xmlReportPaths=$JACOCO_REPORT_PATH" >> sonar-project.properties
  fi
fi

# --- Test classification ------------------------------------------------------
# Without `sonar.tests`, every `*_test.go`, `test_*.py`, `*.spec.ts`... is
# analyzed as production code, so the table-driven scaffolding that tests
# legitimately repeat is counted against "Duplication on New Code". SonarSource's
# pattern for a repository whose sources and tests share one tree is
# `sonar.sources=.` with `sonar.tests=.`, `sonar.test.inclusions` naming the test
# files and the same patterns repeated in `sonar.exclusions`, so that no file is
# indexed as both.
SONAR_TEST_FILE_PATTERNS='**/*_test.go,**/test/**,**/tests/**,**/test_*.py,**/*_test.py,**/conftest.py,**/*.test.ts,**/*.test.tsx,**/*.spec.ts,**/*.spec.tsx,**/*.test.js,**/*.spec.js,**/__tests__/**,**/src/test/**,**/*Tests/**,**/*.Tests/**,**/spec/**'
SONAR_GENERATED_PATTERNS='**/vendor/**,**/node_modules/**,**/build/**,**/dist/**,**/coverage/**,**/.pipelines/**'

# The four keys below are derived as ONE unit. `sonar.sources=.` only yields a
# disjoint main/test split when `sonar.exclusions` matches the test scope, and
# an overlap is not a warning: sonar-scanner aborts with "can't be indexed
# twice". So a repository that declares any part of the classification owns all
# of it, and nothing is bolted onto its half.
if has_sonar_property sonar.sources || has_sonar_property sonar.tests \
  || has_sonar_property sonar.test.inclusions || has_sonar_property sonar.exclusions; then
  echo "Keeping the test classification from sonar-project.properties (sonar.sources/tests/test.inclusions/exclusions are derived only as a set)"
else
  set_default_sonar_property sonar.sources .
  set_default_sonar_property sonar.tests .
  set_default_sonar_property sonar.test.inclusions "$SONAR_TEST_FILE_PATTERNS"
  set_default_sonar_property sonar.exclusions "$SONAR_TEST_FILE_PATTERNS,$SONAR_GENERATED_PATTERNS"
fi
# `sonar.test.exclusions` only ever shrinks the test set, so it cannot create the
# overlap above and stays an independent default.
set_default_sonar_property sonar.test.exclusions '**/vendor/**,**/node_modules/**'

# --- githubactions:S7637 ("Use full commit SHA hash for this dependency") -----
# The rule flags every `uses:` that is not pinned to a 40-character commit SHA,
# and that includes this repository's own reusable workflows referenced as
# `<owner>/pipelines/...@main`. Floating on `main` for FIRST-PARTY workflows is
# deliberate -- the pipelines repository is the single source of truth and pins
# every third-party action itself -- so the rule is ignored for a workflow file
# ONLY when every `uses:` in it is first-party, local (`./`) or SHA-pinned. A
# file with one unpinned third-party action keeps every finding it has, which
# is the point of the rule. The owners trusted as first-party come from
# SONAR_FIRST_PARTY_OWNERS (comma separated) or the owner of GITHUB_REPOSITORY.

# Print the `uses:` references of a workflow or action file, one per line,
# without quotes, trailing comments or carriage returns. Anchored to a YAML key
# (`^ indent [- ] uses:`) so prose and commented-out lines are not read.
list_uses_references() {
  awk '
    /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/ {
      sub(/\r$/, "")
      sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "")
      sub(/[[:space:]]+#.*$/, "")
      sub(/[[:space:]]+$/, "")
      sub(/^["'\'']/, "")
      sub(/["'\'']$/, "")
      if ($0 != "") print
    }' "$1"
}

# Succeed and print why when the reference is exempt from the SHA-pin
# requirement under this policy; fail silently otherwise. Owners compare
# case-insensitively because GitHub resolves them that way.
uses_reference_exemption() {
  case "$1" in
    ./*)
      echo "local"
      return 0
      ;;
  esac
  _ref_sha=${1##*@}
  if [ "$_ref_sha" != "$1" ] && printf '%s' "$_ref_sha" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "SHA-pinned"
    return 0
  fi
  _ref_owner=${1%%/*}
  [ "$_ref_owner" != "$1" ] || return 1
  _ref_owner=$(printf '%s' "$_ref_owner" | tr '[:upper:]' '[:lower:]')
  for _trusted_owner in $SONAR_FIRST_PARTY_OWNER_LIST; do
    if [ "$_trusted_owner" = "$_ref_owner" ]; then
      echo "first-party"
      return 0
    fi
  done
  return 1
}

# Print why the file is accepted (exit 0) or which reference blocks it (exit 1).
# A file without any `uses:` prints nothing and exits 1: it has no S7637
# finding to ignore.
first_party_file_verdict() {
  _fp_refs=$(list_uses_references "$1")
  [ -n "$_fp_refs" ] || return 1
  _fp_count=0
  while IFS= read -r _fp_ref; do
    if ! uses_reference_exemption "$_fp_ref" > /dev/null; then
      echo "'$_fp_ref' is neither first-party, local nor pinned to a commit SHA"
      return 1
    fi
    _fp_count=$((_fp_count + 1))
  done <<EOF
$_fp_refs
EOF
  echo "all $_fp_count uses: references are first-party, local or SHA-pinned"
}

# Print the workflow and composite-action files GitHub reads, one per line,
# as the project-relative paths SonarQube keys them by.
list_github_workflow_files() {
  {
    if [ -d .github/workflows ]; then
      find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \)
    fi
    if [ -d .github/actions ]; then
      find .github/actions -type f \( -name 'action.yml' -o -name 'action.yaml' \)
    fi
  } | sort
}

# Print the ids the repository already lists in sonar.issue.ignore.multicriteria
# (the last definition wins, as the scanner reads it), normalized to `a,b,c`.
existing_multicriteria_ids() {
  { grep -E '^[[:space:]]*sonar\.issue\.ignore\.multicriteria[[:space:]]*=' sonar-project.properties 2>/dev/null || true; } \
    | tail -n 1 | sed 's/^[^=]*=//' | tr -d '[:space:]' | sed 's/,,*/,/g; s/^,//; s/,$//'
}

# Succeed when the id is already used by the repository's own ignore rules.
multicriteria_id_taken() {
  case ",$2," in
    *",$1,"*) return 0 ;;
  esac
  has_sonar_property "sonar.issue.ignore.multicriteria.$1.ruleKey"
}

# Append one S7637 ignore rule per accepted file, then rewrite the single
# `sonar.issue.ignore.multicriteria` list so it also keeps every id the
# repository defined itself -- a second `sonar.issue.ignore.multicriteria=` line
# would replace the first instead of extending it.
write_first_party_ignores() {
  _fp_ids=$(existing_multicriteria_ids)
  { grep -Ev '^[[:space:]]*sonar\.issue\.ignore\.multicriteria[[:space:]]*=' sonar-project.properties || true; } > sonar-project.properties.tmp
  mv sonar-project.properties.tmp sonar-project.properties
  _fp_n=1
  _fp_new_ids=""
  while IFS= read -r _fp_file; do
    [ -n "$_fp_file" ] || continue
    while multicriteria_id_taken "fp$_fp_n" "$_fp_ids"; do
      _fp_n=$((_fp_n + 1))
    done
    {
      printf 'sonar.issue.ignore.multicriteria.fp%s.ruleKey=githubactions:S7637\n' "$_fp_n"
      printf 'sonar.issue.ignore.multicriteria.fp%s.resourceKey=%s\n' "$_fp_n" "$_fp_file"
    } >> sonar-project.properties
    _fp_new_ids="${_fp_new_ids:+$_fp_new_ids,}fp$_fp_n"
    _fp_n=$((_fp_n + 1))
  done <<EOF
$1
EOF
  _fp_ids="${_fp_ids:+$_fp_ids,}$_fp_new_ids"
  printf 'sonar.issue.ignore.multicriteria=%s\n' "$_fp_ids" >> sonar-project.properties
  echo "Updated sonar.issue.ignore.multicriteria=$_fp_ids"
}

accept_first_party_workflow_references() {
  _fp_files=$(list_github_workflow_files)
  [ -n "$_fp_files" ] || return 0
  if [ -n "${SONAR_FIRST_PARTY_OWNERS:-}" ]; then
    _fp_owners=$SONAR_FIRST_PARTY_OWNERS
  elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    _fp_owners=${GITHUB_REPOSITORY%%/*}
  else
    echo "No first-party owner known (SONAR_FIRST_PARTY_OWNERS and GITHUB_REPOSITORY are unset): githubactions:S7637 findings are left as reported."
    return 0
  fi
  SONAR_FIRST_PARTY_OWNER_LIST=$(printf '%s' "$_fp_owners" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')
  echo "Trusting first-party owners for githubactions:S7637: $_fp_owners"
  _fp_accepted=""
  while IFS= read -r _fp_file; do
    if _fp_verdict=$(first_party_file_verdict "$_fp_file"); then
      echo "Accepting $_fp_file for githubactions:S7637: $_fp_verdict"
      _fp_accepted="$_fp_accepted$_fp_file
"
    elif [ -n "$_fp_verdict" ]; then
      echo "Keeping githubactions:S7637 findings in $_fp_file: $_fp_verdict"
    fi
  done <<EOF
$_fp_files
EOF
  [ -n "$_fp_accepted" ] || return 0
  write_first_party_ignores "$_fp_accepted"
}

accept_first_party_workflow_references

sonar-scanner
