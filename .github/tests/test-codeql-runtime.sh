#!/usr/bin/env bash
# Where CodeQL runs, and with what, for every language this library analyses -- GitLab CI's
# `sast:codeql` above all.
#
# The shared GitLab CI job ran in the pipeline's default `docker:x.y` image, which is Alpine (musl),
# so until 2026-10-29 no GitLab CI analysis ran at all, for Go, Java, Python, JavaScript or C#: the
# image has no `curl` and BusyBox's `wget` rejects `--https-only`, so the bundle never downloaded,
# and where it was in place its glibc Java runtime could not start (`java: not found`). That is
# KI-02 in `.docs/known-issues.md`. It was also the kind of break a reader cannot see in a template:
# the image a job runs in is rarely written on the job. It comes from the abstract the job extends,
# and an `image:` written in the wrong place silently outranks it.
#
# So the templates are resolved here the way GitLab resolves them -- `include:` (a `remote:` URL
# into this repository is read from the file it serves), `extends:` and `!reference` -- and, for
# every entry template whose includes reach the shared job, this asserts that:
#   * every file it includes exists, and the job's stage is one the template declares
#   * the job runs in an image pinned by digest, built on glibc, and has what the language's
#     extractor needs: the Go toolchain, a JDK with the project's build tool, the .NET SDK, Node.js
#     for TypeScript, a Python 3 -- in the image, or installed by the job
#   * it installs `jq`, which the findings gate reads the SARIF with, has `git` before
#     `.scripts-repo` clones the scripts and `curl` or `wget` for the bundle download, and installs
#     with `apt-get` only where that works: as root, on a distribution whose archive still serves
#     it (not Debian 11)
#   * it restores no cache: a module cache in the checkout is extracted as hundreds of extra Go
#     projects, and a restored Java build can mark the compilation up to date, so the extractor sees
#     nothing compiled
#   * a language stage moves only WHERE the job runs, and for C# how it builds: the script, the
#     report and the stage stay the shared job's, and the report is where `run.sh` writes it
# and, of the shared job, that its default image sits on the abstract it extends rather than on the
# job, so an override's `extends` can replace it. Then, beyond GitLab CI:
#   * `run.sh` keeps its report when the build deletes `build/` -- the Java autobuilder runs
#     Gradle's `clean` -- and hands `database create` the build mode the job sets, or none
#   * every Azure DevOps language stage hands its CodeQL job the toolchain its other jobs set up
#   * the GitHub Actions composite sets up Node.js for a JavaScript analysis on a self-hosted runner
#   * no GitLab CI image is Debian 11, whose packages no longer install (KI-04): the abstracts that
#     left it stay pinned and off it, and the jobs that install packages run where `apt-get` works
#
# What an image ships cannot be read from a template, and this suite runs no container: the table
# in IMAGE_FACTS records what each image was observed to carry, and an image it has no row for
# fails until somebody looks and adds one. The Docker reproduction that proved each language's job
# end to end -- a planted finding failing the gate, a clean project passing it -- sources this file
# and runs `codeql_job_script`, so it runs exactly the commands asserted on here.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

SHARED_JOB_FILE='gitlab/global/stages/20-security/codeql.yaml'
JOB='sast:codeql'
REMOTE_PREFIX='https://raw.githubusercontent.com/rios0rios0/pipelines/main/'

# What an image ships, observed on 2026-10-29 with
#
#   docker run --rm --entrypoint sh <image> -c 'id -un; ldd --version | head -1; command -v <tool>'
#
# and, for `apt`, an `apt-get update && apt-get install jq` in it. Each row is
# `<glob over repository:tag, digest left off>|<libc>|<what it carries>`, and the FIRST matching row
# wins, so the musl and Debian 11 rows come before the rows they would otherwise shadow
# (`gradle:8.7.0-jdk21-alpine` is not `gradle:8.7.0-jdk21`). `root` means the image runs its jobs as
# root, and `apt` that `apt-get install` works there. `debian11` marks Debian 11, where it does not:
# its security updates left the Debian mirrors when its LTS ended -- the index still lists them, and
# the packages answer 404 -- which is how `report:dependency-track` and the Maven
# `sca:dependency-check` stopped installing anything (KI-04 in `.docs/known-issues.md`). These are
# facts about upstream images, not choices: a row is added after looking, never to make this suite
# pass. None of them ships `jq`. Two rows are rules rather than observations: Alpine is built on
# musl, and every Debian 11 image has the same archive.
IMAGE_FACTS=(
  'docker:*|musl|root wget'
  'gradle:*-alpine|musl|root java gradle git wget python3'
  '*alpine*|musl|'
  'node:*-bullseye|glibc|root node git curl debian11'
  'maven:3.8-jdk-11-slim|glibc|root java mvn curl debian11'
  '*bullseye*|glibc|debian11'
  'node:*-bookworm|glibc|root apt node git curl'
  'python:*-slim*|glibc|root apt python3'
  'golang:*-bookworm|glibc|root apt go git curl'
  'maven:*-eclipse-temurin-*|glibc|root apt java mvn git curl'
  'gradle:*-jdk*|glibc|root apt java gradle git curl'
  'mcr.microsoft.com/dotnet/sdk:*|glibc|root apt dotnet git curl'
)

# What each language's extractor needs, by the security stage that includes the shared job:
# `<stage>|<CODEQL_LANGUAGE>|<CODEQL_BUILD_MODE>|<needs>`. An empty build mode is the CLI's default,
# which BUILDS Go, Java and C# to extract them, so they need the toolchain and the project's build
# tool. C# is extracted without a build on GitLab CI (`none`), because those pipelines build .NET
# Framework projects on Windows runners, but the extractor still restores their NuGet dependencies
# with `dotnet`. The JavaScript extractor parses TypeScript by running the TypeScript compiler on
# Node.js, which the bundle does not ship, and the Python extractor runs on the Python 3 it finds on
# PATH. A stage that includes the shared job without a row here fails, so a language added later is
# asked the question instead of inheriting an answer.
EXTRACTOR_NEEDS=(
  'gitlab/golang/stages/20-security/go.yaml|go||go'
  'gitlab/python/stages/20-security/pdm.yaml|python||python3'
  'gitlab/javascript/stages/20-security/yarn.yaml|javascript||node'
  'gitlab/java/stages/20-security/gradle.yaml|java||java gradle'
  'gitlab/java/stages/20-security/maven.yaml|java||java mvn'
  'gitlab/dotnet/stages/20-security/csharp.yaml|csharp|none|dotnet'
)

# The Debian package that provides a need, where the two are named apart.
declare -A PACKAGE_OF=([node]='nodejs')

# What each Azure DevOps language stage hands the shared CodeQL template through `PRE_STEPS`:
# `<stage>|<setup task>|<the input holding its version>|<the abstract the language's other jobs set
# it up with>`. The Python extractor needs a Python and the JavaScript one a Node.js for TypeScript;
# the Go, Java and C# ones build the code.
AZURE_TOOLCHAINS=(
  'azure-devops/golang/stages/20-security/go.yaml|GoTool@0|version|azure-devops/golang/abstracts/go.yaml'
  'azure-devops/python/stages/20-security/pdm.yaml|UsePythonVersion@0|versionSpec|azure-devops/python/abstracts/pdm-python3.14.yaml'
  'azure-devops/javascript/stages/20-security/yarn.yaml|UseNode@1|version|azure-devops/javascript/abstracts/corepack-node-no-cache.yaml'
  'azure-devops/java/stages/20-security/java.yaml|JavaToolInstaller@0|versionSpec|azure-devops/java/abstracts/gradle.yaml'
  'azure-devops/dotnet/stages/20-security/csharp.yaml|UseDotNet@2|version|azure-devops/dotnet/abstracts/core-sdk6.x.yaml'
)

# The GitLab CI abstracts that left Debian 11 (`<file>|<abstract>`), and the jobs on them that
# install packages (`<entry template>|<job>`): the two KI-04 found unable to install anything.
ABSTRACTS_OFF_DEBIAN_11=(
  'gitlab/javascript/abstracts/npm.yaml|.npm'
  'gitlab/javascript/abstracts/yarn.yaml|.yarn'
  'gitlab/java/abstracts/maven.yaml|.maven'
)
INSTALLING_JOBS=(
  'gitlab/javascript/yarn-docker.yaml|report:dependency-track'
  'gitlab/java/maven-docker.yaml|sca:dependency-check'
)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1" condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_empty() {
  local description="$1" findings="$2"
  if [[ -z "$findings" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    printf '%s\n' "$findings" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# ---------------------------------------------------------------------------
# The resolver
# ---------------------------------------------------------------------------
# Only what decides where and how a job runs: `include:`, `extends:` and `!reference`. GitLab merges
# included files in order with later ones winning and a file winning over what it includes, deep for
# mappings, replacing sequences -- which is yq's `*` -- and then applies `extends` the same way, the
# job's own keys last.

codeql_runtime_setup() {
  TEST_DIR="$(mktemp -d)" || return 1
  RESOLVE_DIR="$TEST_DIR/resolved"
  mkdir -p "$RESOLVE_DIR" || return 1
  . "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
  . "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"
  . "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"
  YQ=""
  resolve_yq "$TEST_DIR/yqbin" || {
    echo "could not resolve mikefarah/yq; cannot run this suite" >&2
    return 1
  }
}

codeql_runtime_teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
  return 0
}

# gitlab_includes <template> -- the files it includes, repository-relative, in order. A `remote:`
# URL outside this repository is printed as it is, so it never resolves and is reported.
gitlab_includes() {
  local entry
  while IFS= read -r entry; do
    case "$entry" in
      "$REMOTE_PREFIX"*) printf '%s\n' "${entry#"$REMOTE_PREFIX"}" ;;
      /*) printf '%s\n' "${entry#/}" ;;
      ?*) printf '%s\n' "$entry" ;;
    esac
  done < <("$YQ" eval '(.include // []) | ((select(tag == "!!seq") | .[]), select(tag != "!!seq")) | (select(tag == "!!str") // .remote // .local // "")' "$SCRIPTS_DIR/$1" 2> /dev/null)
}

# gitlab_closure <template> -- the template and everything it includes, in GitLab's merge order,
# as `file <path>` lines, plus a `missing <path> <includer>` line for an include that names no file.
declare -A GITLAB_SEEN=()
gitlab_closure_walk() {
  local template="$1" includer="$2" included
  [[ -n "${GITLAB_SEEN[$template]:-}" ]] && return 0
  GITLAB_SEEN[$template]=1
  if [[ ! -f "$SCRIPTS_DIR/$template" ]]; then
    printf 'missing %s %s\n' "$template" "$includer"
    return 0
  fi
  while IFS= read -r included; do
    gitlab_closure_walk "$included" "$template"
  done < <(gitlab_includes "$template")
  printf 'file %s\n' "$template"
}
gitlab_closure() {
  GITLAB_SEEN=()
  gitlab_closure_walk "$1" ''
}

# gitlab_document <template> -- the path of a file holding the template's whole configuration,
# merged as GitLab merges it.
gitlab_document() {
  local template="$1" out files=() kind path
  out="$RESOLVE_DIR/$(printf '%s' "$template" | tr '/' '_')"
  if [[ ! -f "$out" ]]; then
    while read -r kind path _; do
      [[ "$kind" == 'file' ]] && files+=("$SCRIPTS_DIR/$path")
    done < <(gitlab_closure "$template")
    "$YQ" eval-all '. as $item ireduce ({}; . * $item)' "${files[@]}" > "$out" 2> /dev/null || : > "$out"
  fi
  printf '%s\n' "$out"
}

# gitlab_job <document> <job> -- the path of a file holding the job with `extends` applied.
gitlab_job() {
  local document="$1" job="$2" out own parent layers=()
  out="$RESOLVE_DIR/job-$(printf '%s|%s' "$document" "$job" | sha256sum | cut -c1-16).yaml"
  if [[ ! -f "$out" ]]; then
    own="$out.own"
    JOB_NAME="$job" "$YQ" eval '.[strenv(JOB_NAME)] // {}' "$document" > "$own" 2> /dev/null || echo '{}' > "$own"
    while IFS= read -r parent; do
      [[ -n "$parent" ]] && layers+=("$(gitlab_job "$document" "$parent")")
    done < <("$YQ" eval '(.extends // []) | ((select(tag == "!!seq") | .[]), select(tag == "!!str"))' "$own" 2> /dev/null)
    "$YQ" eval 'del(.extends)' "$own" > "$own.self" 2> /dev/null || echo '{}' > "$own.self"
    "$YQ" eval-all '. as $item ireduce ({}; . * $item)' "${layers[@]}" "$own.self" > "$out" 2> /dev/null || echo '{}' > "$out"
  fi
  printf '%s\n' "$out"
}

# gitlab_ancestors <document> <job> -- every job the job extends, directly or not, one per line.
gitlab_ancestors() {
  local document="$1" job="$2" parent
  while IFS= read -r parent; do
    [[ -z "$parent" ]] && continue
    printf '%s\n' "$parent"
    gitlab_ancestors "$document" "$parent"
  done < <(JOB_NAME="$job" "$YQ" eval '.[strenv(JOB_NAME)].extends // [] | ((select(tag == "!!seq") | .[]), select(tag == "!!str"))' "$document" 2> /dev/null)
}

# gitlab_lines <document> <job> <key> -- the entries of a script key (`before_script`, `script`)
# with every `!reference` replaced by what it names, each followed by a NUL.
gitlab_lines() {
  local document="$1" job="$2" key="$3" resolved tag count index
  resolved="$(gitlab_job "$document" "$job")"
  tag="$(KEY="$key" "$YQ" eval '.[strenv(KEY)] | tag' "$resolved" 2> /dev/null)"
  case "$tag" in
    '!reference')
      gitlab_lines "$document" \
        "$(KEY="$key" "$YQ" eval '.[strenv(KEY)][0]' "$resolved")" \
        "$(KEY="$key" "$YQ" eval '.[strenv(KEY)][1]' "$resolved")"
      ;;
    '!!str')
      KEY="$key" "$YQ" -0 eval '.[strenv(KEY)]' "$resolved"
      ;;
    '!!seq')
      count="$(KEY="$key" "$YQ" eval '.[strenv(KEY)] | length' "$resolved")"
      for ((index = 0; index < count; index++)); do
        tag="$(KEY="$key" INDEX="$index" "$YQ" eval '.[strenv(KEY)][env(INDEX)] | tag' "$resolved")"
        if [[ "$tag" == '!reference' ]]; then
          gitlab_lines "$document" \
            "$(KEY="$key" INDEX="$index" "$YQ" eval '.[strenv(KEY)][env(INDEX)][0]' "$resolved")" \
            "$(KEY="$key" INDEX="$index" "$YQ" eval '.[strenv(KEY)][env(INDEX)][1]' "$resolved")"
        else
          KEY="$key" INDEX="$index" "$YQ" -0 eval '.[strenv(KEY)][env(INDEX)]' "$resolved"
        fi
      done
      ;;
  esac
}

# The image a job runs in: its own (after `extends`), else the pipeline's default -- the template's,
# or, for a stage file read on its own, the one every entry template here includes.
gitlab_job_image() {
  local document="$1" job="$2" resolved image expression
  expression='.image | (select(tag == "!!map") | .name) // .'
  resolved="$(gitlab_job "$document" "$job")"
  image="$("$YQ" eval "$expression" "$resolved" 2> /dev/null)"
  if [[ -z "$image" || "$image" == 'null' ]]; then
    image="$("$YQ" eval ".default | $expression" "$document" 2> /dev/null)"
  fi
  if [[ -z "$image" || "$image" == 'null' ]]; then
    image="$("$YQ" eval ".default | $expression" "$SCRIPTS_DIR/gitlab/global/abstracts/default-image.yaml" 2> /dev/null)"
  fi
  [[ "$image" == 'null' ]] && image=''
  printf '%s\n' "$image"
}

# The user an image is told to run the job as, when the template says so.
gitlab_job_user() {
  local resolved
  resolved="$(gitlab_job "$1" "$2")"
  "$YQ" eval '.image.docker.user // ""' "$resolved" 2> /dev/null
}

# image_facts <image> -- `<libc>|<carries>` from IMAGE_FACTS, or nothing when no row matches.
image_facts() {
  local reference="${1%%@*}" row pattern
  for row in "${IMAGE_FACTS[@]}"; do
    pattern="${row%%|*}"
    # shellcheck disable=SC2053 # the right-hand side is a glob on purpose
    if [[ "$reference" == $pattern ]]; then
      printf '%s\n' "${row#*|}"
      return 0
    fi
  done
  return 0
}

# The security stage whose include of the shared job brings it into a template.
codeql_stage_of() {
  local template="$1" kind path
  while read -r kind path _; do
    [[ "$kind" == 'file' ]] || continue
    gitlab_includes "$path" | grep -qxF "$SHARED_JOB_FILE" && printf '%s\n' "$path"
  done < <(gitlab_closure "$template")
}

# codeql_job_script <template> -- the commands GitLab runs for the template's `sast:codeql`, its
# `before_script` then its `script`, as one shell script.
codeql_job_script() {
  local document
  document="$(gitlab_document "$1")"
  { gitlab_lines "$document" "$JOB" before_script; gitlab_lines "$document" "$JOB" script; } \
    | tr '\0' '\n'
}

codeql_job_image() {
  gitlab_job_image "$(gitlab_document "$1")" "$JOB"
}

# codeql_job_variable <template> <name> -- a variable as the job sees it: its own, else the
# template's.
codeql_job_variable() {
  local document resolved value
  document="$(gitlab_document "$1")"
  resolved="$(gitlab_job "$document" "$JOB")"
  value="$(NAME="$2" "$YQ" eval '.variables[strenv(NAME)] // ""' "$resolved" 2> /dev/null)"
  [[ -z "$value" ]] && value="$(NAME="$2" "$YQ" eval '.variables[strenv(NAME)] // ""' "$document" 2> /dev/null)"
  printf '%s\n' "$value"
}

codeql_job_language() {
  codeql_job_variable "$1" CODEQL_LANGUAGE
}

# ---------------------------------------------------------------------------
# Line predicates over a job's NUL-separated `before_script`
# ---------------------------------------------------------------------------

# The index of the first entry installing <tool> with apt-get or apk, or nothing.
install_index() {
  local tool="$1" entry index=0 flat pattern
  # The package manager, its `install`/`add`, then the tool as a whole word, with only options and
  # other package names between them: `apt-get remove jq`, `echo jq` and `jqx` do not count, and
  # neither does a word after a `;`, `&&` or `|`, which starts another command.
  pattern="(apt-get|apt|apk)([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(install|add)([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+${tool}([[:space:]]|\$)"
  while IFS= read -r -d '' entry; do
    flat="$(printf '%s' "$entry" | tr '\\\n' '  ')"
    if [[ "$flat" =~ $pattern ]]; then
      printf '%s\n' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 0
}

# The index of the first entry matching an extended regular expression, or nothing.
entry_index() {
  local pattern="$1" entry index=0
  while IFS= read -r -d '' entry; do
    if printf '%s' "$entry" | grep -qE -- "$pattern"; then
      printf '%s\n' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 0
}

carries() {
  [[ " $1 " == *" $2 "* ]]
}

# apt_works <carried> <user> -- whether `apt-get install` works for a job: the image runs it as
# root, and its distribution's archive still serves its packages.
apt_works() {
  carries "$1" root && carries "$1" apt && [[ -z "$2" || "$2" == 'root' ]]
}

# ---------------------------------------------------------------------------
# The assertions
# ---------------------------------------------------------------------------

check_template() {
  local template="$1" stage="$2" language="$3" build_mode="$4" needs="$5"
  local document resolved shared_document shared_resolved image facts libc carried user
  local missing need lines first_clone git_at jq_at curl_at wget_at git_ready undefined ancestor stage_name

  document="$(gitlab_document "$template")"
  resolved="$(gitlab_job "$document" "$JOB")"
  shared_document="$(gitlab_document "$SHARED_JOB_FILE")"
  shared_resolved="$(gitlab_job "$shared_document" "$JOB")"

  echo ""
  echo "$template (through $stage)"

  missing="$(gitlab_closure "$template" | awk '$1 == "missing" { print $2 " (included by " $3 ")" }')"
  assert_empty "every file it includes exists" "$missing"

  undefined=''
  while IFS= read -r ancestor; do
    [[ -z "$ancestor" ]] && continue
    JOB_NAME="$ancestor" "$YQ" eval -e 'has(strenv(JOB_NAME))' "$document" > /dev/null 2>&1 \
      || undefined="${undefined}${ancestor}"$'\n'
  done < <(gitlab_ancestors "$document" "$JOB" | sort -u)
  assert_empty "every abstract $JOB extends is defined" "$undefined"

  assert_true "it analyses CODEQL_LANGUAGE '$language'" \
    "[[ \"\$(codeql_job_language '$template')\" == '$language' ]]"
  assert_true "it builds the database in build mode '${build_mode:-the CLI default}'" \
    "[[ \"\$(codeql_job_variable '$template' CODEQL_BUILD_MODE)\" == '$build_mode' ]]"

  image="$(gitlab_job_image "$document" "$JOB")"
  facts="$(image_facts "$image")"
  libc="${facts%%|*}"
  carried="${facts#*|}"
  user="$(gitlab_job_user "$document" "$JOB")"

  assert_true "it runs in an image pinned by digest (${image:-none})" \
    "[[ '$image' =~ @sha256:[0-9a-f]{64}$ ]]"
  assert_true "IMAGE_FACTS records what ${image%%@*} ships" "[[ -n '$facts' ]]"
  assert_true "the image is built on glibc, which the bundle's Java runtime needs (${libc:-unknown})" \
    "[[ '$libc' == 'glibc' ]]"
  lines="$TEST_DIR/lines.$$"
  gitlab_lines "$document" "$JOB" before_script > "$lines"

  # A need is met by the image or by the job's own install; a Debian package can be named apart
  # from the command it provides (`nodejs` installs `node`).
  for need in $needs; do
    assert_true "it has $need, which the $language extractor needs" \
      "carries '$carried' '$need' || [[ -n \"\$(install_index '${PACKAGE_OF[$need]:-$need}' < '$lines')\" ]]"
  done

  first_clone="$(entry_index 'git (-C [^ ]+ )?(init|clone|fetch)' < "$lines")"
  git_at="$(install_index git < "$lines")"
  jq_at="$(install_index jq < "$lines")"
  curl_at="$(install_index curl < "$lines")"
  wget_at="$(install_index wget < "$lines")"

  # Computed before asserting, so an index that is absent reads as false rather than as a syntax
  # error in the condition.
  git_ready=false
  if [[ -n "$first_clone" ]]; then
    if carries "$carried" git || { [[ -n "$git_at" ]] && ((git_at < first_clone)); }; then
      git_ready=true
    fi
  fi
  assert_true "it installs jq, which the findings gate reads the SARIF with" "[[ -n '$jq_at' ]]"
  assert_true "it has git before .scripts-repo clones the scripts" "$git_ready"
  assert_true "it has curl or wget for the bundle download" \
    "carries '$carried' curl || carries '$carried' wget || [[ -n '$curl_at$wget_at' ]]"
  if grep -qzE '(apt-get|apt)[[:space:]]' "$lines"; then
    assert_true "apt-get can install there: the image runs the job as root (${user:-image default}) on a distribution its archive still serves" \
      "apt_works '$carried' '$user'"
  fi
  rm -f "$lines"

  assert_true "it restores no cache" \
    "\"\$YQ\" eval -e '.cache | ((tag == \"!!null\") or (length == 0))' '$resolved' > /dev/null 2>&1"

  assert_true "it runs the shared job's script" \
    "[[ \"\$(gitlab_lines '$document' '$JOB' script | tr '\\0' '\\n')\" == \"\$(gitlab_lines '$shared_document' '$JOB' script | tr '\\0' '\\n')\" ]]"
  assert_true "it publishes the shared job's report" \
    "[[ \"\$(\"\$YQ\" eval '.artifacts' '$resolved')\" == \"\$(\"\$YQ\" eval '.artifacts' '$shared_resolved')\" ]]"
  stage_name="$("$YQ" eval '.stage // ""' "$resolved")"
  assert_true "it keeps the shared job's stage, and the template declares it ('$stage_name')" \
    "[[ '$stage_name' == \"\$(\"\$YQ\" eval '.stage // \"\"' '$shared_resolved')\" ]] && STAGE='$stage_name' \"\$YQ\" eval -e '(.stages // []) | any_c(. == strenv(STAGE))' '$document' > /dev/null 2>&1"
}

main() {
  codeql_runtime_setup || exit 1
  trap codeql_runtime_teardown EXIT

  echo "================================"
  echo "CodeQL runtime"
  echo "================================"

  # -------------------------------------------------------------------------
  echo ""
  echo "1. The shared job"
  # -------------------------------------------------------------------------
  local shared_document shared_resolved report tool_name file_name
  shared_document="$(gitlab_document "$SHARED_JOB_FILE")"
  shared_resolved="$(gitlab_job "$shared_document" "$JOB")"

  # An `image:` on the job itself outranks the image an override takes through `extends` (`.go`,
  # `.maven`, `.sdk`), so every override would analyse in the default image: Go with no Go.
  assert_true "its default image sits on the abstract it extends, not on the job" \
    "! \"\$YQ\" eval -e '.\"$JOB\" | has(\"image\")' '$SCRIPTS_DIR/$SHARED_JOB_FILE' > /dev/null 2>&1"
  assert_true "the default image is not the pipeline's Alpine default ($(gitlab_job_image "$shared_document" "$JOB"))" \
    "[[ \"\$(image_facts \"\$(gitlab_job_image '$shared_document' '$JOB')\")\" == glibc\\|* ]]"
  assert_true "the shared job runs run.sh with the stage's CODEQL_LANGUAGE" \
    "gitlab_lines '$shared_document' '$JOB' script | tr '\\0' '\\n' | grep -qE 'global/scripts/tools/codeql/run\\.sh \"?\\\$CODEQL_LANGUAGE\"?$'"

  # `run.sh` writes its report under the per-tool directory `cleanup.sh` creates. A report path
  # without it uploads nothing, with only a `no matching files` warning in the log to say so.
  tool_name="$(grep -oE '^TOOL_NAME="[a-z]+"' "$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh" | cut -d'"' -f2)"
  file_name="$(grep -oE '^fileName="\$\(pwd\)/\$REPORT_PATH/[^"]+"' "$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh" | sed 's|.*\$REPORT_PATH/||; s|"$||')"
  report="$("$YQ" eval '.artifacts.reports.sast // ""' "$shared_resolved")"
  assert_true "its report is where run.sh writes it (\$REPORT_PATH/${tool_name:-?}/${file_name:-?}; the job publishes $report)" \
    "[[ -n '$tool_name' && -n '$file_name' && '$report' == \"\\\$REPORT_PATH/$tool_name/$file_name\" ]]"

  # -------------------------------------------------------------------------
  echo ""
  echo "2. Every entry template that runs CodeQL"
  # -------------------------------------------------------------------------
  local template stage row language build_mode needs found_row unknown_stages='' covered=''
  while IFS= read -r template; do
    template="${template#"$SCRIPTS_DIR/"}"
    stage="$(codeql_stage_of "$template" | head -1)"
    [[ -z "$stage" ]] && continue
    found_row=''
    for row in "${EXTRACTOR_NEEDS[@]}"; do
      if [[ "${row%%|*}" == "$stage" ]]; then
        found_row="$row"
        break
      fi
    done
    if [[ -z "$found_row" ]]; then
      unknown_stages="${unknown_stages}${stage} (reached from ${template})"$'\n'
      continue
    fi
    IFS='|' read -r _ language build_mode needs <<< "$found_row"
    covered="${covered}${stage}"$'\n'
    check_template "$template" "$stage" "$language" "$build_mode" "$needs"
  done < <(find "$SCRIPTS_DIR/gitlab" -mindepth 2 -maxdepth 2 -name '*.yaml' -type f | sort)

  # -------------------------------------------------------------------------
  echo ""
  echo "3. Every language stays analysed"
  # -------------------------------------------------------------------------
  assert_empty "every security stage that includes the shared job has a row in EXTRACTOR_NEEDS" "$unknown_stages"
  # A language that stops reaching the shared job looks exactly like one nobody thought of, so
  # dropping one has to be a decision this file is edited for. The likeliest cause is an include
  # that names no file, which GitLab refuses to load the whole template over -- the Maven template
  # included `2-security/` and `3-tests/` paths that have not existed since 2023 -- so the entry
  # templates beside the stage are listed with any such include.
  local not_covered='' language_dir sibling broken
  for row in "${EXTRACTOR_NEEDS[@]}"; do
    stage="${row%%|*}"
    grep -qxF "$stage" <<< "$covered" && continue
    not_covered="${not_covered}${stage}"$'\n'
    language_dir="${stage%%/stages/*}"
    for sibling in "$SCRIPTS_DIR/$language_dir"/*.yaml; do
      [[ -f "$sibling" ]] || continue
      sibling="${sibling#"$SCRIPTS_DIR/"}"
      broken="$(gitlab_closure "$sibling" | awk '$1 == "missing" { print $2 " (included by " $3 ")" }')"
      [[ -n "$broken" ]] && not_covered="${not_covered}  ${sibling} includes files that do not exist: $(tr '\n' ' ' <<< "$broken")"$'\n'
    done
  done
  assert_empty "every stage in EXTRACTOR_NEEDS is reached by an entry template" "$not_covered"

  # -------------------------------------------------------------------------
  echo ""
  echo "4. run.sh: the report survives the build, and the build mode is the job's"
  # -------------------------------------------------------------------------
  # `codeql` is a stub here, recording what `database create` was handed. Its `database create`
  # deletes `build/` as Gradle's `clean` does -- the Java autobuilder runs it, and on a CI runner
  # the build runs in the checkout, so the report directory `cleanup.sh` made before the build went
  # with it -- and its `database analyze` refuses to write into a directory that does not exist, as
  # the real one does (`Could not write SARIF file`).
  local stub_bin status record
  stub_bin="$TEST_DIR/stub-bin"
  mkdir -p "$stub_bin" "$TEST_DIR/stub-home" || exit 1
  cat > "$stub_bin/codeql" << 'STUB'
#!/usr/bin/env sh
command="$1 $2"
shift 2
case "$command" in
  'database create')
    printf '%s\n' "$@" > "$CODEQL_STUB_RECORD"
    for argument in "$@"; do
      case "$argument" in
        --source-root=*) root="${argument#--source-root=}" ;;
      esac
      database="$argument"
    done
    rm -rf "$root/build"
    mkdir -p "$database"
    ;;
  'database analyze')
    for argument in "$@"; do
      case "$argument" in
        --output=*) output="${argument#--output=}" ;;
      esac
    done
    if [ ! -d "$(dirname "$output")" ]; then
      echo 'A fatal error occurred: Could not write SARIF file' >&2
      exit 2
    fi
    printf '%s\n' '{"version":"2.1.0","runs":[{"results":[]}]}' > "$output"
    ;;
esac
exit 0
STUB
  chmod +x "$stub_bin/codeql"

  # run_stubbed <label> [NAME=value...] -- run.sh over a fresh project, as on a CI runner; the exit
  # status lands in $TEST_DIR/<label>.status, the output in .log, and the stub's record in .args.
  run_stubbed() {
    local label="$1" project="$TEST_DIR/project-$1" code=0
    shift
    mkdir -p "$project" || return 1
    (
      cd "$project" || exit 1
      env -u TF_BUILD -u CODEQL_THREADS -u CODEQL_SOURCE_SCOPE -u CODEQL_RAM -u CODEQL_BUILD_MODE \
        CI=true HOME="$TEST_DIR/stub-home" PATH="$stub_bin:$PATH" SCRIPTS_DIR="$SCRIPTS_DIR" \
        CODEQL_STUB_RECORD="$TEST_DIR/$label.args" "$@" \
        "$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh" java
    ) > "$TEST_DIR/$label.log" 2>&1 || code=$?
    echo "$code" > "$TEST_DIR/$label.status"
  }

  run_stubbed default
  status="$(cat "$TEST_DIR/default.status")"
  assert_true "a build that deletes build/ still ends in the gate's verdict (exit $status), not in a report it could not write" \
    "[[ '$status' == 0 ]] && ! grep -q 'Could not write SARIF file' '$TEST_DIR/default.log'"
  assert_true "the report is where the job publishes it (build/reports/codeql/codeql.sarif)" \
    "[[ -f '$TEST_DIR/project-default/build/reports/codeql/codeql.sarif' ]]"
  assert_true "with CODEQL_BUILD_MODE unset, no --build-mode is passed: the CLI default, as on GitHub Actions" \
    "[[ -f '$TEST_DIR/default.args' ]] && ! grep -q -- '--build-mode' '$TEST_DIR/default.args'"

  run_stubbed none CODEQL_BUILD_MODE=none
  assert_true "CODEQL_BUILD_MODE=none reaches database create as --build-mode=none" \
    "grep -qx -- '--build-mode=none' '$TEST_DIR/none.args' 2> /dev/null"

  run_stubbed bogus CODEQL_BUILD_MODE=bogus
  record="$(cat "$TEST_DIR/bogus.status")"
  assert_true "an unknown CODEQL_BUILD_MODE stops the scan before CodeQL runs (exit $record)" \
    "[[ '$record' != 0 && ! -f '$TEST_DIR/bogus.args' ]] && grep -q 'CODEQL_BUILD_MODE must be' '$TEST_DIR/bogus.log'"

  # -------------------------------------------------------------------------
  echo ""
  echo "5. Azure DevOps hands each language's CodeQL job its toolchain"
  # -------------------------------------------------------------------------
  # The Azure DevOps job runs on whatever agent the pipeline picks, and an extractor that builds the
  # code, or parses TypeScript, finds its toolchain there or not at all: an agent without one failed
  # the analysis, and the step's `continueOnError` reported that as passed with issues. Each
  # language stage hands the template the setup task its other jobs run, at the same version, in
  # `PRE_STEPS`, which the template runs before `run.sh` (section 3c of
  # `test-go-module-toolchain.sh`).
  local entry azure_stage task input abstract passed expected azure_stages='' unlisted=''
  for entry in "${AZURE_TOOLCHAINS[@]}"; do
    IFS='|' read -r azure_stage task input abstract <<< "$entry"
    azure_stages="${azure_stages}${azure_stage}"$'\n'
    passed="$(TASK="$task" INPUT="$input" "$YQ" eval '.. | select(tag == "!!map" and has("template")) | select(.template | test("20-security/codeql\.yaml$")) | (.parameters.PRE_STEPS // [])[] | select(.task == strenv(TASK)) | .inputs[strenv(INPUT)]' "$SCRIPTS_DIR/$azure_stage" 2> /dev/null | head -1)"
    expected="$(TASK="$task" INPUT="$input" "$YQ" eval '.steps[] | select(.task == strenv(TASK)) | .inputs[strenv(INPUT)]' "$SCRIPTS_DIR/$abstract" 2> /dev/null | head -1)"
    assert_true "$azure_stage passes CodeQL $task ${passed:-(none)}, as its other jobs run it (${expected:-(none)})" \
      "[[ -n '$passed' && '$passed' == '$expected' ]]"
  done
  # A stage that calls the template without a row here was never asked what its extractor needs.
  while IFS= read -r azure_stage; do
    azure_stage="${azure_stage#"$SCRIPTS_DIR/"}"
    grep -qxF "$azure_stage" <<< "$azure_stages" || unlisted="${unlisted}${azure_stage}"$'\n'
  done < <(grep -rlE "template: '[./]*global/stages/20-security/codeql\.yaml'" "$SCRIPTS_DIR/azure-devops" --include='*.yaml' | sort)
  assert_empty "every Azure DevOps stage that runs CodeQL has a row in AZURE_TOOLCHAINS" "$unlisted"

  # -------------------------------------------------------------------------
  echo ""
  echo "6. GitHub Actions gives the JavaScript analysis a Node.js"
  # -------------------------------------------------------------------------
  # A GitHub-hosted runner carries Node.js; a self-hosted one, where `npm.yaml` and `yarn.yaml` can
  # send the CodeQL job (`codeql_runs_on`), need not, and the TypeScript extraction then stops at
  # `Could not start Node.js`. The composite sets one up before `init`, as it does Go -- with no
  # package cache, which on a self-hosted runner would untar into a `$HOME` that persists.
  local composite node_at init_at
  composite="$SCRIPTS_DIR/github/global/stages/20-security/codeql/action.yaml"
  node_at="$("$YQ" eval '.runs.steps | to_entries | .[] | select((.value.uses // "") | test("^actions/setup-node@")) | select((.value.if // "") | test("javascript-typescript")) | .key' "$composite" 2> /dev/null | head -1)"
  init_at="$("$YQ" eval '.runs.steps | to_entries | .[] | select((.value.uses // "") | test("^github/codeql-action/init@")) | .key' "$composite" 2> /dev/null | head -1)"
  assert_true "the composite sets up Node.js for javascript-typescript" "[[ -n '$node_at' ]]"
  assert_true "...before init, so the extractor finds it (step ${node_at:-?} of init's ${init_at:-?})" \
    "[[ -n '$node_at' && -n '$init_at' ]] && ((${node_at:-0} < ${init_at:-0}))"
  assert_true "...and restores no package cache" \
    "INDEX='${node_at:-0}' \"\$YQ\" eval -e '.runs.steps[env(INDEX)].with | ((has(\"cache\") | not) and (.\"package-manager-cache\" == false))' '$composite' > /dev/null 2>&1"

  # -------------------------------------------------------------------------
  echo ""
  echo "7. No GitLab CI image is Debian 11"
  # -------------------------------------------------------------------------
  # Debian 11's packages no longer install (KI-04), so a job that installs one there fails before it
  # does any work: `report:dependency-track` and the Maven `sca:dependency-check` did exactly that,
  # in `.npm`'s and `.maven`'s images. The abstracts moved to Debian 12 and Ubuntu 22.04; this keeps
  # them there, keeps the two jobs on an image `apt-get` works in, and keeps every other image any
  # GitLab CI template names off Debian 11 too.
  local abstract_file abstract job document image facts user image_facts_carried installing file named
  local debian11=''
  for entry in "${ABSTRACTS_OFF_DEBIAN_11[@]}"; do
    IFS='|' read -r abstract_file abstract <<< "$entry"
    document="$(gitlab_document "$abstract_file")"
    image="$(gitlab_job_image "$document" "$abstract")"
    facts="$(image_facts "$image")"
    assert_true "$abstract runs in an image pinned by digest (${image:-none})" \
      "[[ '$image' =~ @sha256:[0-9a-f]{64}$ ]]"
    assert_true "...that IMAGE_FACTS records, and that is not Debian 11 (${facts:-no row})" \
      "[[ -n '$facts' ]] && ! carries '${facts#*|}' debian11"
  done
  for entry in "${INSTALLING_JOBS[@]}"; do
    IFS='|' read -r template job <<< "$entry"
    document="$(gitlab_document "$template")"
    image="$(gitlab_job_image "$document" "$job")"
    facts="$(image_facts "$image")"
    image_facts_carried="${facts#*|}"
    user="$(gitlab_job_user "$document" "$job")"
    installing="$TEST_DIR/installing.$$"
    { gitlab_lines "$document" "$job" before_script; gitlab_lines "$document" "$job" script; } > "$installing"
    assert_true "$template: $job installs packages with apt-get" \
      "grep -qzE '(apt-get|apt)[[:space:]]+(-[^ ]+[[:space:]]+)*install' '$installing'"
    assert_true "...where apt-get can install them: as root, on a distribution its archive still serves (${image%%@*})" \
      "apt_works '$image_facts_carried' '$user'"
    rm -f "$installing"
  done
  while IFS= read -r file; do
    while IFS= read -r named; do
      [[ -z "$named" ]] && continue
      facts="$(image_facts "$named")"
      carries "${facts#*|}" debian11 && debian11="${debian11}${file#"$SCRIPTS_DIR/"}: ${named}"$'\n'
    done < <("$YQ" eval '.. | select(tag == "!!map") | select(has("image")) | .image | ((select(tag == "!!map") | .name) // .) | select(tag == "!!str")' "$file" 2> /dev/null)
  done < <(find "$SCRIPTS_DIR/gitlab" -name '*.yaml' -type f | sort)
  assert_empty "no GitLab CI template names a Debian 11 image" "$debian11"

  echo ""
  echo "================================"
  echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
    echo "================================"
    exit 1
  fi
  echo "================================"
  echo -e "${GREEN}CodeQL runs where every extractor can${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
