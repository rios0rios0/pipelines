#!/usr/bin/env bash
set -e

# Every toolchain that reads a `go.mod` must be new enough for the `go` directive in it.
#
# The directive is a MINIMUM LANGUAGE VERSION -- a requirement the module states -- and every
# `go` invocation refuses one newer than itself, before parsing:
#
#   go: go.mod requires go >= 1.27.0 (running go 1.26.6; GOTOOLCHAIN=local)
#
# That is not a warning it recovers from. The build, the tidy, the dependency download and any
# external analyser all fail identically, and none of the resulting messages names the two
# versions that disagree in a way a reader can act on.
#
# This repository paid for it twice, from one automated dependency bump:
#
#   - `Build & Push tor-proxy:latest` broke on 2026-07-27 and stayed broken for over three
#     weeks. Its Dockerfile still pinned `golang:1.19.0-alpine3.16`. The failure reads
#     `go: errors parsing go.mod`, which names no version at all.
#   - `Analyze (go)` -- then GitHub's DEFAULT-SETUP CodeQL -- broke on 2026-08-20 and failed ten
#     consecutive runs on `main` and on every pull request. Its runner ships one Go and sets
#     `GOTOOLCHAIN=local` deliberately, so it cannot fetch another: extraction failed for the
#     only Go project in the repository, which CodeQL reports as a *configuration error* rather
#     than as a finding.
#
# **The fix is upward, in both places, and the direction is the point.** The module says what it
# needs; the toolchains follow. Lowering the directive to suit the oldest thing that reads it
# would make this green by giving up whatever the module is entitled to use, and would have to be
# done again on every future release -- a ratchet running the wrong way. The builder image was
# raised to the directive, and the Go analysis now installs the toolchain the module asks for
# (`go_version_file` on `github/global/stages/20-security/codeql`) instead of hoping the runner
# image already carries it -- and on GitLab CI and Azure DevOps, the pinned Go (section 3c).
#
# So no version is pinned anywhere in this file; the one table, in section 4, records which CodeQL
# release first read each Go, a fact about upstream rather than a choice. What is asserted is the
# RELATIONSHIP: nothing that has to read a module may be older than the module, and the Go
# analysis must bring its own toolchain rather than inherit one it cannot choose.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_empty() {
  local description="$1"
  local findings="$2"
  if [[ -z "$findings" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "         $line"
    done <<< "$findings"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_true() {
  local description="$1"
  local condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# version_le <a> <b> -- true when a <= b, comparing Go versions field by field.
#
# `sort -V` is deliberately not used: it is a GNU extension that BusyBox `sort`
# does not implement, and these suites are expected to give the same answer on a
# maintainer's Alpine container as on a GitHub runner. Three numeric fields is
# the whole grammar of a Go version here, so comparing them is shorter than
# depending on a flag that may not exist.
version_le() {
  local a="$1" b="$2" i
  local -a fa fb
  IFS='.' read -r -a fa <<< "$a"
  IFS='.' read -r -a fb <<< "$b"
  for i in 0 1 2; do
    local x="${fa[i]:-0}" y="${fb[i]:-0}"
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 0
}

echo "================================"
echo "Go module toolchain agreement"
echo "================================"
echo ""

# ---------------------------------------------------------------------------
echo "1. Every go.mod is paired with a builder that can read it"
# ---------------------------------------------------------------------------
# The pairing rule is positional and deliberately dumb: a `go.mod` is compiled by
# the Dockerfile of the container folder it lives under. A clever rule would
# quietly stop matching the day somebody adds a second arrangement -- which is the
# failure mode this whole file exists to prevent -- so a module with no Dockerfile
# above it is reported rather than skipped. The one exception is the repository's
# own module at the root, which holds the Go helpers and has a pairing of its own
# (section 1b), written when it was added rather than assumed.
ROOT_MODULE="$SCRIPTS_DIR/go.mod"
MODULE_COUNT=0
FINDINGS=""

while IFS= read -r gomod; do
  [[ -z "$gomod" ]] && continue
  MODULE_COUNT=$((MODULE_COUNT + 1))
  [[ "$gomod" == "$ROOT_MODULE" ]] && continue

  directive="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$gomod" | head -1 | awk '{print $2}')"
  if [[ -z "$directive" ]]; then
    FINDINGS+="${gomod#"$SCRIPTS_DIR"/}: declares no 'go' directive"$'\n'
    continue
  fi

  dockerfile=""
  dir="$(dirname "$gomod")"
  while [[ "$dir" != "$SCRIPTS_DIR" && "$dir" != "/" ]]; do
    if [[ -f "$dir/Dockerfile" ]]; then
      dockerfile="$dir/Dockerfile"
      break
    fi
    dir="$(dirname "$dir")"
  done

  if [[ -z "$dockerfile" ]]; then
    FINDINGS+="${gomod#"$SCRIPTS_DIR"/}: no Dockerfile above it, so nothing pins the Go that builds it"$'\n'
    continue
  fi

  builder="$(grep -oE '^FROM +golang:[0-9]+(\.[0-9]+)*' "$dockerfile" | head -1 | sed 's/.*golang://')"
  if [[ -z "$builder" ]]; then
    FINDINGS+="${dockerfile#"$SCRIPTS_DIR"/}: no 'FROM golang:<version>' stage builds ${gomod#"$SCRIPTS_DIR"/}"$'\n'
    continue
  fi

  if ! version_le "$directive" "$builder"; then
    FINDINGS+="${gomod#"$SCRIPTS_DIR"/}: 'go $directive' exceeds its builder golang:$builder — go build will refuse to parse it"$'\n'
  fi
done < <(find "$SCRIPTS_DIR" -type f -name 'go.mod' -not -path '*/.git/*' | sort)

assert_empty "no go.mod declares a directive its builder image cannot read" "$FINDINGS"
assert_true "at least one Go module was actually examined" "[[ $MODULE_COUNT -ge 1 ]]"
echo ""

# ---------------------------------------------------------------------------
echo "1b. The root module is paired with every template that builds it"
# ---------------------------------------------------------------------------
# The root `go.mod` holds the Go helpers. No Dockerfile builds it: each helper is
# compiled on the runner through `global/scripts/shared/go-helper.sh`, so its builders
# are the CI jobs that run a helper, and the Go they provision. The relationship is the
# one section 1 asserts -- no builder older than the directive -- and both sides are
# FOUND rather than listed, so a helper or a template added later is covered without
# anyone remembering this file:
#
#   - a helper's entry is every script under `global/` that calls `go_helper_run <dir>`
#     for a `main.go` of this module, and, followed to a fixed point, every script that
#     runs one of those by path -- `test-all/run.sh` runs `terra-test/run.sh`, which runs
#     the coverage generator, so a template running `test-all/run.sh` builds a helper;
#   - a builder is a JOB, not a file, because the Go is provisioned per job: a workflow
#     whose other jobs pin Go says nothing about the one that runs the checker. A GitHub
#     Actions job pins `go-version:`, and may hand a consumer's `go.mod` to setup-go only
#     where it holds that file to this one's directive (`.pipelines/go.mod`); a GitLab CI
#     job runs on a `golang:<version>` image of its own or of the job it extends; an
#     Azure DevOps job installs Go with a `GoTool@0` task of its own.
#
# The rules are functions of a repository root, so the fixtures at the end of this
# section can prove each one fires against a deliberate violation.

# code <file> [first last] -- a file's lines, or a range of them, comments dropped: a
# comment that names a script documents it, it does not run it. `pinned-versions.sh`
# names the dependency-updates runner in a comment, and every installer sources it.
code() {
  if [[ $# -eq 3 ]]; then
    sed -n "${2},${3}p" "$1"
  else
    cat "$1"
  fi | grep -vE '^[[:space:]]*#'
}

# contains <needle> <haystack...> -- true when the needle is one of the words.
contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# helper_entries <root> -- the scripts, relative to <root>, that build a Go helper.
helper_entries() {
  local root="$1" script package nested module_dir entry relative
  local -a entries=() scripts=()
  local nested_modules
  nested_modules="$(find "$root" -mindepth 2 -type f -name 'go.mod' -not -path '*/.git/*' -exec dirname {} \;)"
  while IFS= read -r script; do
    scripts+=("$script")
  done < <(find "$root/global" -type f -name '*.sh' 2> /dev/null | sort)
  for script in "${scripts[@]}"; do
    while IFS= read -r package; do
      [[ -n "$package" && -f "$root/$package/main.go" ]] || continue
      nested=false
      while IFS= read -r module_dir; do
        [[ -n "$module_dir" && "$root/$package/" == "$module_dir/"* ]] && nested=true
      done <<< "$nested_modules"
      [[ "$nested" == false ]] && entries+=("${script#"$root"/}")
    done < <(code "$script" | grep -oE 'go_helper_run[[:space:]]+[A-Za-z0-9_./-]+' | awk '{print $2}')
  done
  local changed=true
  while [[ "$changed" == true ]]; do
    changed=false
    for script in "${scripts[@]}"; do
      relative="${script#"$root"/}"
      [[ ${#entries[@]} -gt 0 ]] && contains "$relative" "${entries[@]}" && continue
      for entry in "${entries[@]}"; do
        if code "$script" | grep -qF "$entry"; then
          entries+=("$relative")
          changed=true
          break
        fi
      done
    done
  done
  [[ ${#entries[@]} -gt 0 ]] && printf '%s\n' "${entries[@]}" | sort -u
}

# names_entry <file> <first-line> <last-line> -- true when those lines run a helper entry.
names_entry() {
  local file="$1" first="$2" last="$3" entry
  for entry in "${ENTRIES[@]}"; do
    code "$file" "$first" "$last" | grep -qF "$entry" && return 0
  done
  return 1
}

# github_units <file> -- `first last name` for every job of a workflow, or the whole file
# for a composite action, which has no jobs.
github_units() {
  local file="$1" units
  units="$(awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^[^ #]/ { if (name != "") print start, NR - 1, name; name = ""; in_jobs = 0; next }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      if (name != "") print start, NR - 1, name
      name = $1; sub(/:$/, "", name); start = NR
    }
    END { if (name != "") print start, NR, name }
  ' "$file")"
  if [[ -n "$units" ]]; then
    echo "$units"
  else
    echo "1 $(wc -l < "$file") (action)"
  fi
}

# github_findings <root> <directive> -- every GitHub Actions job that builds a helper with
# no pinned Go, an older one, or a consumer's go.mod not held to the directive.
GITHUB_JOBS=0
github_findings() {
  local root="$1" directive="$2" file first last name versions version label
  while IFS= read -r file; do
    while read -r first last name; do
      names_entry "$file" "$first" "$last" \
        || sed -n "${first},${last}p" "$file" | grep -qE '^ *run: *make test *$' \
        || continue
      GITHUB_JOBS=$((GITHUB_JOBS + 1))
      label="${file#"$root"/} job $name"
      versions="$(sed -n "${first},${last}p" "$file" | grep -oE "go-version: *'[0-9]+(\.[0-9]+)*'" \
        | grep -oE "[0-9]+(\.[0-9]+)*" || true)"
      if [[ -z "$versions" ]]; then
        echo "$label: builds a Go helper with no 'go-version' pinned, so nothing pins the Go that builds it"
      fi
      for version in $versions; do
        version_le "$directive" "$version" \
          || echo "$label: go-version '$version' is older than go.mod's 'go $directive' -- go build will refuse to parse it"
      done
      if sed -n "${first},${last}p" "$file" | grep -q 'go-version-file:' \
        && ! sed -n "${first},${last}p" "$file" | grep -qF '.pipelines/go.mod'; then
        echo "$label: lets a consumer's go.mod choose the Go that builds a helper without holding it to 'go $directive'"
      fi
    done < <(github_units "$file")
  done < <(find "$root/.github/workflows" "$root/github" -type f -name '*.yaml' 2> /dev/null | sort)
}

# gitlab_block <file> <job> -- the lines of a top-level GitLab CI job.
gitlab_block() {
  awk -v job="$2" '
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    line == job ":" { inside = 1; next }
    inside && /^[^ #]/ { exit }
    inside { print }
  ' "$1"
}

# gitlab_includes <root> <file> -- the files of this repository a template includes.
gitlab_includes() {
  grep -oE "remote: *'https://raw\.githubusercontent\.com/rios0rios0/pipelines/[^/']+/[^']+'" "$2" \
    | sed -E "s|.*/rios0rios0/pipelines/[^/]+/||; s|'$||" | while IFS= read -r path; do
      [[ -f "$1/$path" ]] && echo "$1/$path"
    done
}

# gitlab_image <root> <file> <job> [depth] -- the image a job runs on: its own `image:`, or
# that of the job it extends, looked up in its file and in the files it includes.
gitlab_image() {
  local root="$1" file="$2" job="$3" depth="${4:-0}" block image parent candidate
  [[ "$depth" -gt 5 ]] && return 0
  block="$(gitlab_block "$file" "$job")"
  image="$(echo "$block" | grep -oE "^  image: *'[^']+'" | head -1 | sed -E "s/^  image: *'//; s/'$//")"
  if [[ -n "$image" ]]; then
    echo "$image"
    return 0
  fi
  parent="$(echo "$block" | grep -oE "^  extends: *'[^']+'" | head -1 | sed -E "s/^  extends: *'//; s/'$//")"
  [[ -n "$parent" ]] || return 0
  for candidate in "$file" $(gitlab_includes "$root" "$file"); do
    if grep -qE "^${parent//./\\.}:[[:space:]]*$" "$candidate"; then
      gitlab_image "$root" "$candidate" "$parent" $((depth + 1))
      return 0
    fi
  done
}

# gitlab_findings <root> <directive> -- every GitLab CI job that builds a helper on an image
# that is not a golang one at least as new as the directive.
GITLAB_JOBS=0
gitlab_findings() {
  local root="$1" directive="$2" file job image version
  while IFS= read -r file; do
    while IFS= read -r job; do
      gitlab_block "$file" "$job" | grep -vE '^[[:space:]]*#' | grep -qF -f <(printf '%s\n' "${ENTRIES[@]}") || continue
      GITLAB_JOBS=$((GITLAB_JOBS + 1))
      image="$(gitlab_image "$root" "$file" "$job")"
      version="$(echo "$image" | grep -oE '^golang:[0-9]+(\.[0-9]+)*' | sed 's/^golang://')"
      if [[ -z "$version" ]]; then
        echo "${file#"$root"/} job $job: builds a Go helper on '${image:-no image}', not a golang:<version> image"
      elif ! version_le "$directive" "$version"; then
        echo "${file#"$root"/} job $job: golang:$version is older than go.mod's 'go $directive' -- go build will refuse to parse it"
      fi
    done < <(grep -oE '^[A-Za-z0-9][^ ]*:[[:space:]]*$' "$file" | sed -E 's/:[[:space:]]*$//' \
      | grep -vxE 'include|stages|variables|default|workflow|image|services|cache|before_script|after_script')
  done < <(find "$root/gitlab" -type f -name '*.yaml' 2> /dev/null | sort)
}

# azure_jobs <file> -- `first last name` for every `- job:` of a template, a job ending at
# the next line indented no deeper than its own `-`.
azure_jobs() {
  awk '
    function flush() { if (name != "") print start, last, name; name = "" }
    {
      if (name != "" && $0 !~ /^[[:space:]]*$/) {
        match($0, /^ */)
        if (RLENGTH <= indent) flush()
      }
      if ($0 ~ /^ *- job: */) {
        flush()
        match($0, /^ */); indent = RLENGTH; start = NR
        name = $0; sub(/^ *- job: */, "", name); gsub(/'\''/, "", name)
      }
      if (name != "") last = NR
    }
    END { flush() }
  ' "$1"
}

# azure_findings <root> <directive> -- every Azure DevOps job that builds a helper with no
# `GoTool@0` of its own, or an older one.
AZURE_JOBS=0
azure_findings() {
  local root="$1" directive="$2" file first last name versions version
  while IFS= read -r file; do
    while read -r first last name; do
      names_entry "$file" "$first" "$last" || continue
      AZURE_JOBS=$((AZURE_JOBS + 1))
      versions="$(sed -n "${first},${last}p" "$file" | awk '
        /GoTool@0/ { ahead = 8; next }
        ahead > 0 { ahead--; if (match($0, /version: *'\''[0-9.]+'\''/)) { v = substr($0, RSTART, RLENGTH); gsub(/[^0-9.]/, "", v); print v; ahead = 0 } }
      ')"
      if [[ -z "$versions" ]]; then
        echo "${file#"$root"/} job $name: builds a Go helper with no GoTool@0 'version' in the job, so nothing pins the Go that builds it"
      fi
      for version in $versions; do
        version_le "$directive" "$version" \
          || echo "${file#"$root"/} job $name: GoTool@0 version '$version' is older than go.mod's 'go $directive' -- go build will refuse to parse it"
      done
    done < <(azure_jobs "$file")
  done < <(find "$root/azure-devops" -type f -name '*.yaml' 2> /dev/null | sort)
}

if [[ -f "$ROOT_MODULE" ]]; then
  ROOT_DIRECTIVE="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$ROOT_MODULE" | head -1 | awk '{print $2}')"
  assert_true "the root module declares a 'go' directive" "[[ -n '$ROOT_DIRECTIVE' ]]"

  ENTRIES=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && ENTRIES+=("$entry")
  done < <(helper_entries "$SCRIPTS_DIR")
  assert_true "the root module's helpers were found (${#ENTRIES[@]} entry scripts)" "[[ ${#ENTRIES[@]} -ge 1 ]]"
  # The indirect chain is the case direct discovery misses: no template names the
  # coverage generator, they name the runners that reach it.
  assert_true "a helper reached through another script is found: test-all/run.sh" \
    "contains global/scripts/languages/terraform/test-all/run.sh ${ENTRIES[*]}"

  assert_empty "every GitHub Actions job that builds a Go helper provisions a Go that can read go.mod" \
    "$(github_findings "$SCRIPTS_DIR" "$ROOT_DIRECTIVE")"
  GITHUB_JOBS=0
  github_findings "$SCRIPTS_DIR" "$ROOT_DIRECTIVE" > /dev/null
  assert_true "the GitHub Actions jobs that build it were found ($GITHUB_JOBS)" "[[ $GITHUB_JOBS -ge 1 ]]"

  assert_empty "every GitLab CI job that builds a Go helper runs on a golang image that can read go.mod" \
    "$(gitlab_findings "$SCRIPTS_DIR" "$ROOT_DIRECTIVE")"
  GITLAB_JOBS=0
  gitlab_findings "$SCRIPTS_DIR" "$ROOT_DIRECTIVE" > /dev/null
  assert_true "the GitLab CI jobs that build it were found ($GITLAB_JOBS)" "[[ $GITLAB_JOBS -ge 1 ]]"

  assert_empty "every Azure DevOps job that builds a Go helper installs a Go that can read go.mod" \
    "$(azure_findings "$SCRIPTS_DIR" "$ROOT_DIRECTIVE")"
  AZURE_JOBS=0
  azure_findings "$SCRIPTS_DIR" "$ROOT_DIRECTIVE" > /dev/null
  assert_true "the Azure DevOps jobs that build it were found ($AZURE_JOBS)" "[[ $AZURE_JOBS -ge 1 ]]"

  # Each rule is shown to fire against a deliberate violation, beside a compliant twin
  # it must leave alone: a rule that passes everything would make the checks above pass
  # for the worst possible reason.
  FIXTURE="$(mktemp -d)" || exit 1
  trap 'rm -rf "$FIXTURE"' EXIT
  mkdir -p "$FIXTURE/global/scripts/helper" "$FIXTURE/global/scripts/wrapper" "$FIXTURE/.github/workflows" \
    "$FIXTURE/github" "$FIXTURE/gitlab/x/abstracts" "$FIXTURE/gitlab/x/stages" "$FIXTURE/azure-devops/x"
  printf 'module example.com/fixture\n\ngo 1.25.0\n' > "$FIXTURE/go.mod"
  printf 'package main\n\nfunc main() {}\n' > "$FIXTURE/global/scripts/helper/main.go"
  printf '#!/usr/bin/env sh\ngo_helper_run global/scripts/helper "$@"\n' > "$FIXTURE/global/scripts/helper/run.sh"
  printf '#!/usr/bin/env sh\n"$SCRIPTS_DIR/global/scripts/helper/run.sh"\n' > "$FIXTURE/global/scripts/wrapper/run.sh"
  cat > "$FIXTURE/.github/workflows/fixture.yaml" << 'YAML'
on: push
jobs:
  no_go:
    steps:
      - run: '$SCRIPTS_DIR/global/scripts/wrapper/run.sh'
  old_go:
    steps:
      - uses: 'actions/setup-go@x'
        with:
          go-version: '1.24.9'
      - run: '$SCRIPTS_DIR/global/scripts/helper/run.sh'
  unguarded_file:
    steps:
      - uses: 'actions/setup-go@x'
        with:
          go-version-file: 'tests/go.mod'
      - uses: 'actions/setup-go@x'
        with:
          go-version: '1.27.3'
      - run: '$SCRIPTS_DIR/global/scripts/wrapper/run.sh'
  github_good:
    steps:
      - uses: 'actions/setup-go@x'
        with:
          go-version: '1.27.3'
      - run: '$SCRIPTS_DIR/global/scripts/wrapper/run.sh'
YAML
  cat > "$FIXTURE/gitlab/x/abstracts/old.yaml" << 'YAML'
.old-go:
  image: 'golang:1.24.9@sha256:0000'
.new-go:
  image: 'golang:1.27.3-bookworm@sha256:0000'
YAML
  cat > "$FIXTURE/gitlab/x/stages/fixture.yaml" << 'YAML'
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/x/abstracts/old.yaml'

python_image:
  image: 'python:3.13-alpine@sha256:0000'
  script:
    - "$SCRIPTS_DIR/global/scripts/wrapper/run.sh"

extends_old:
  extends: '.old-go'
  script:
    - "$SCRIPTS_DIR/global/scripts/helper/run.sh"

no_image:
  script:
    - "$SCRIPTS_DIR/global/scripts/helper/run.sh"

gitlab_good:
  extends: '.new-go'
  script:
    - "$SCRIPTS_DIR/global/scripts/wrapper/run.sh"
YAML
  cat > "$FIXTURE/azure-devops/x/fixture.yaml" << 'YAML'
stages:
  - stage: 'fixture'
    jobs:
      - job: 'no_gotool'
        steps:
          - script: $(Scripts.Directory)/global/scripts/wrapper/run.sh
      - job: 'old_gotool'
        steps:
          - task: 'GoTool@0'
            inputs:
              version: '1.24.9'
          - script: $(Scripts.Directory)/global/scripts/helper/run.sh
      - job: 'azure_good'
        steps:
          - task: 'GoTool@0'
            displayName: 'Use Go'
            inputs:
              version: '1.27.3'
          - script: $(Scripts.Directory)/global/scripts/wrapper/run.sh
YAML
  REAL_ENTRIES=("${ENTRIES[@]}")
  ENTRIES=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && ENTRIES+=("$entry")
  done < <(helper_entries "$FIXTURE")
  assert_true "discovery follows a script that runs a helper's script (fixture)" \
    "contains global/scripts/wrapper/run.sh ${ENTRIES[*]}"
  # shellcheck disable=SC2034  # read inside assert_true's eval'd conditions
  FIXTURE_GITHUB="$(github_findings "$FIXTURE" 1.25.0)"
  # shellcheck disable=SC2034  # read inside assert_true's eval'd conditions
  FIXTURE_GITLAB="$(gitlab_findings "$FIXTURE" 1.25.0)"
  # shellcheck disable=SC2034  # read inside assert_true's eval'd conditions
  FIXTURE_AZURE="$(azure_findings "$FIXTURE" 1.25.0)"
  assert_true "the GitHub rule fires on a job with no pinned Go" "grep -q 'job no_go: .*no .go-version.' <<< \"\$FIXTURE_GITHUB\""
  assert_true "the GitHub rule fires on a job with an older Go" "grep -q \"job old_go: go-version '1.24.9'\" <<< \"\$FIXTURE_GITHUB\""
  assert_true "the GitHub rule fires on a consumer's go.mod not held to the directive" \
    "grep -q 'job unguarded_file: lets a consumer' <<< \"\$FIXTURE_GITHUB\""
  assert_true "the GitHub rule leaves a compliant job alone" "! grep -q 'github_good' <<< \"\$FIXTURE_GITHUB\""
  assert_true "the GitLab rule fires on a job on a non-golang image" "grep -q \"job python_image: .*'python:3.13\" <<< \"\$FIXTURE_GITLAB\""
  assert_true "the GitLab rule fires on a job extending an older golang image" \
    "grep -q 'job extends_old: golang:1.24.9 is older' <<< \"\$FIXTURE_GITLAB\""
  assert_true "the GitLab rule fires on a job with no image at all" "grep -q \"job no_image: .*'no image'\" <<< \"\$FIXTURE_GITLAB\""
  assert_true "the GitLab rule leaves a job extending a new enough image alone" "! grep -q 'gitlab_good' <<< \"\$FIXTURE_GITLAB\""
  assert_true "the Azure rule fires on a job with no GoTool@0" "grep -q 'job no_gotool: .*no GoTool@0' <<< \"\$FIXTURE_AZURE\""
  assert_true "the Azure rule fires on a job with an older GoTool@0" \
    "grep -q \"job old_gotool: GoTool@0 version '1.24.9'\" <<< \"\$FIXTURE_AZURE\""
  assert_true "the Azure rule leaves a compliant job alone" "! grep -q 'azure_good' <<< \"\$FIXTURE_AZURE\""
  ENTRIES=("${REAL_ENTRIES[@]}")
fi
echo ""

# ---------------------------------------------------------------------------
echo "2. The comparison itself is sound"
# ---------------------------------------------------------------------------
# A comparison that answered "fine" for everything would make section 1 pass for
# the worst possible reason -- the same silent-pass shape the supply-chain suite
# guards against -- so the comparator is exercised against the exact pair that
# broke, and against the boundaries either side of it.
assert_true "1.27.0 is NOT readable by golang:1.26.6 (the CodeQL failure)" \
  "! version_le 1.27.0 1.26.6"
assert_true "1.27.0 is NOT readable by golang:1.19.0 (the image build failure)" \
  "! version_le 1.27.0 1.19.0"
assert_true "1.27.0 IS readable by golang:1.27.0 (the pairing this commit ships)" \
  "version_le 1.27.0 1.27.0"
assert_true "a newer builder than the directive is fine -- only the reverse breaks" \
  "version_le 1.27.0 1.28.0"
assert_true "a two-field directive is compared as its zero patch" "version_le 1.25 1.25.0"
assert_true "the minor field is compared numerically, not as text" "version_le 1.9.0 1.26.0"
echo ""

# ---------------------------------------------------------------------------
echo "3. The Go analysis brings its own toolchain"
# ---------------------------------------------------------------------------
# The builder image is ours and its failure is loud. The ANALYSER's toolchain is
# not: it belongs to GitHub, is declared nowhere in this repository, and moves on
# their schedule -- so "it works today" is not a property anything here can keep.
# The only durable answer is for the analysis to install what the module asks for,
# which is what these assert is still wired.
CODEQL_ACTION="$SCRIPTS_DIR/github/global/stages/20-security/codeql/action.yaml"

assert_true "the shared CodeQL action still exists where the workflows call it" \
  "[[ -f '$CODEQL_ACTION' ]]"
assert_true "the Go analysis installs a toolchain rather than taking the runner's" \
  "grep -q 'actions/setup-go@' '$CODEQL_ACTION'"

# `go-version-file`, never `go-version`. A pinned version here would just move the
# drift into this file and need bumping on every Go release; reading the module's
# own directive means the toolchain cannot be older than the code that requires it.
assert_true "the toolchain is read from the module, not pinned in the action" \
  "grep -q 'go-version-file:' '$CODEQL_ACTION'"
assert_empty "no hardcoded 'go-version:' pin sits beside it" \
  "$(grep -n 'go-version:' "$CODEQL_ACTION" || true)"

# The step is useless if it lands after the database is initialised: the extractor
# resolves `go` from PATH at build time, so a toolchain installed afterwards is a
# toolchain nothing used.
SETUP_GO_LINE="$(grep -n 'actions/setup-go@' "$CODEQL_ACTION" | head -1 | cut -d: -f1)"
INIT_LINE="$(grep -n 'codeql-action/init@' "$CODEQL_ACTION" | head -1 | cut -d: -f1)"
assert_true "the toolchain is installed BEFORE CodeQL initialises its database" \
  "[[ -n '$SETUP_GO_LINE' && -n '$INIT_LINE' && $SETUP_GO_LINE -lt $INIT_LINE ]]"

# This repository analyses itself through that action, and the file it names has to
# be the module that actually exists -- a stale path silently falls back to the
# runner's Go, which is the state this whole file exists to prevent.
SELF_WORKFLOW="$SCRIPTS_DIR/.github/workflows/codeql.yaml"
assert_true "this repository scans itself through the shared action" \
  "[[ -f '$SELF_WORKFLOW' ]] && grep -q '20-security/codeql' '$SELF_WORKFLOW'"

NAMED_FILE="$(grep -oE "go_version_file: *'[^']+'" "$SELF_WORKFLOW" 2> /dev/null | head -1 | sed "s/.*'\\(.*\\)'/\\1/")"
assert_true "the go.mod it names is really there ($NAMED_FILE)" \
  "[[ -n '$NAMED_FILE' && -f '$SCRIPTS_DIR/$NAMED_FILE' ]]"

# Autobuild extracts EVERY module here from the repository root, under the one Go set up from that
# file with `GOTOOLCHAIN=local`. A module whose directive is newer than the named file's could not
# be extracted at all, so the named file has to carry the newest directive in the repository.
NEWEST_DIRECTIVE=""
NEWEST_MODULE=""
while IFS= read -r gomod; do
  [[ -z "$gomod" ]] && continue
  directive="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$gomod" | head -1 | awk '{print $2}')"
  [[ -z "$directive" ]] && continue
  if [[ -z "$NEWEST_DIRECTIVE" ]] || ! version_le "$directive" "$NEWEST_DIRECTIVE"; then
    NEWEST_DIRECTIVE="$directive"
    NEWEST_MODULE="${gomod#"$SCRIPTS_DIR"/}"
  fi
done < <(find "$SCRIPTS_DIR" -type f -name 'go.mod' -not -path '*/.git/*' | sort)
NAMED_DIRECTIVE=""
if [[ -n "$NAMED_FILE" && -f "$SCRIPTS_DIR/$NAMED_FILE" ]]; then
  NAMED_DIRECTIVE="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$SCRIPTS_DIR/$NAMED_FILE" | head -1 | awk '{print $2}')"
fi
assert_true "the go.mod it names carries the newest directive here, go $NEWEST_DIRECTIVE of $NEWEST_MODULE, so its Go reads every module" \
  "[[ -n '$NAMED_DIRECTIVE' && -n '$NEWEST_DIRECTIVE' ]] && version_le '$NEWEST_DIRECTIVE' '$NAMED_DIRECTIVE'"

# The action has to be referenced by LOCAL PATH. `@main` resolves to the copy on the default
# branch, so a pull request changing the action would test the old one and report green on code
# nobody ran -- and an external `uses:` on a branch name is a high-severity SonarCloud finding
# (`githubactions:S7637`) into the bargain. Both were observed on #602 before this line existed.
assert_true "the self-scan runs THIS commit's action, not the published one" \
  "grep -qE \"uses: *'\\./github/global/stages/20-security/codeql'\" '$SELF_WORKFLOW'"
assert_empty "the self-scan does not reference the action through a moving branch" \
  "$(grep -n '20-security/codeql@' "$SELF_WORKFLOW" || true)"
echo ""

# The input is useless if no consumer can reach it, and that is exactly how it shipped
# first: the action grew `go_version_file` while `go.yaml` still called it with two inputs,
# so every consumer going through the reusable workflows kept the old behaviour and the fix
# only ever worked for this repository's own self-scan.
echo ""
echo "3b. Consumers can actually reach the toolchain input"
for wf in go go-docker go-binary go-library go-render; do
  FILE="$SCRIPTS_DIR/.github/workflows/$wf.yaml"
  assert_true "$wf.yaml declares go_version_file" \
    "grep -qE '^ +go_version_file:' '$FILE'"
  # `grep -F`: the needle contains `${{ }}`, which is an unmatched brace to ERE and a
  # parameter expansion to the shell. Fixed-string matching sidesteps both.
  assert_true "$wf.yaml passes it on rather than declaring it decoratively" \
    "grep -qF 'inputs.go_version_file }}' '$FILE'"
done

# The chain has to be unbroken end to end: `go-render` -> `go-docker` -> `go.yaml` -> action.
# Any one link declaring the input without forwarding it looks fine in isolation.
assert_true "go.yaml hands the input to the CodeQL action, not just to itself" \
  "grep -A 4 \"20-security/codeql@main\" '$SCRIPTS_DIR/.github/workflows/go.yaml' | grep -q 'go_version_file:'"

# And when nobody sets it, the action must still find a module that is not at the root --
# otherwise the default silently reproduces the original failure for those repositories.
assert_true "the action searches for the module when the named file is absent" \
  "grep -q 'find . -name go.mod' '$CODEQL_ACTION'"
assert_true "an ambiguous tree is reported rather than guessed at" \
  "grep -q 'Go toolchain not resolved' '$CODEQL_ACTION'"
assert_true "the discovered path is what setup-go is given" \
  "grep -qF 'steps.go_toolchain.outputs.file' '$CODEQL_ACTION'"
echo ""

# ---------------------------------------------------------------------------
echo "3c. The Go analysis has a Go on GitLab CI and Azure DevOps too"
# ---------------------------------------------------------------------------
# GitHub Actions sets the module's Go up above. The other two platforms run CodeQL through
# `run.sh`, and the Go autobuilder builds with whatever `go` is on PATH, so there the JOB decides
# the toolchain -- and a job without one analyses no Go at all:
#
#   - GitLab CI's shared `sast:codeql` runs in the pipeline's default `docker:x.y` image, which is
#     Alpine: the bundle's glibc-linked Java runtime cannot start there (`java: not found`), and
#     the image has no Go. The Go stage moves the job onto `.go`, the image of every other Go job.
#   - Azure DevOps' shared CodeQL job set up no Go. A Microsoft-hosted agent carries Go 1.24 to
#     1.26 and reaches a newer module only by downloading its toolchain; an agent with no Go, or no
#     route to proxy.golang.org, failed the analysis, and `continueOnError` reported that as passed
#     with issues. The Go stage hands the template the `GoTool@0` the other Go jobs run.
GITLAB_GO_SECURITY="$SCRIPTS_DIR/gitlab/golang/stages/20-security/go.yaml"
# The job's own block: from its key to the next line that starts in column 0 -- the next key, or
# the comment above it.
GITLAB_CODEQL_JOB="$(awk '/^sast:codeql:/ { inside = 1; print; next }
  inside && /^[^[:space:]]/ { exit }
  inside { print }' "$GITLAB_GO_SECURITY" 2> /dev/null)"
assert_true "the GitLab CI Go stage overrides the shared sast:codeql job" \
  "[[ -n \"\$GITLAB_CODEQL_JOB\" ]]"
assert_true "it runs in the .go image, which carries glibc and the pinned Go" \
  "grep -qE \"^  extends: .*'\\.go'\" <<< \"\$GITLAB_CODEQL_JOB\""
assert_true "it installs jq, which the findings gate reads the SARIF with" \
  "grep -qE 'apt-get install .*[[:space:]]jq([[:space:]]|$)' <<< \"\$GITLAB_CODEQL_JOB\""
# `.go`'s before_script and cache put GOPATH inside the checkout, and the autobuilder searches the
# whole source root for go.mod files (skipping only `vendor/`): a module cache there is extracted as
# hundreds of extra projects. So the job takes `.go`'s image and nothing else of it.
assert_true "it turns the .go cache off" \
  "grep -qE '^  cache: *\\[ *\\]' <<< \"\$GITLAB_CODEQL_JOB\""
assert_empty "it neither runs .go's before_script nor sets a GOPATH of its own" \
  "$(grep -nE '\.go, *before_script|GOPATH' <<< "$GITLAB_CODEQL_JOB" | grep -vE '^[0-9]+: *#' || true)"
# Only where the job runs is overridden; what it runs stays the shared runner and gate.
assert_empty "it keeps the shared job's script rather than a copy of it" \
  "$(grep -nE '^  script:' <<< "$GITLAB_CODEQL_JOB" || true)"

AZURE_CODEQL="$SCRIPTS_DIR/azure-devops/global/stages/20-security/codeql.yaml"
AZURE_GO_SECURITY="$SCRIPTS_DIR/azure-devops/golang/stages/20-security/go.yaml"
assert_true "the Azure DevOps CodeQL template takes PRE_STEPS" \
  "grep -A1 -E \"name: *'PRE_STEPS'\" '$AZURE_CODEQL' | grep -qE \"type: *'stepList'\""
PRE_STEPS_LINE="$(grep -n 'each step in parameters.PRE_STEPS' "$AZURE_CODEQL" | head -1 | cut -d: -f1)"
RUNNER_LINE="$(grep -n 'global/scripts/tools/codeql/run.sh' "$AZURE_CODEQL" | head -1 | cut -d: -f1)"
assert_true "it runs them BEFORE run.sh, so the extractor builds with what they install" \
  "[[ -n '$PRE_STEPS_LINE' && -n '$RUNNER_LINE' && $PRE_STEPS_LINE -lt $RUNNER_LINE ]]"
# The Go stage's call of that template: from its `- template:` line to the next list item at the
# same indentation.
AZURE_CODEQL_CALL="$(awk '/- template: .*20-security\/codeql\.yaml/ { inside = 1; indent = index($0, "-"); print; next }
  inside { if (match($0, /^ *- /) && RLENGTH == indent + 1) exit; print }' "$AZURE_GO_SECURITY" 2> /dev/null)"
assert_true "the Azure DevOps Go stage passes CodeQL a GoTool@0 step" \
  "grep -q 'PRE_STEPS:' <<< \"\$AZURE_CODEQL_CALL\" && grep -q \"task: 'GoTool@0'\" <<< \"\$AZURE_CODEQL_CALL\""
CODEQL_GO="$(grep -A3 'GoTool@0' <<< "$AZURE_CODEQL_CALL" | grep -oE "version: *'[0-9.]+'" | grep -oE '[0-9][0-9.]*' | head -1)"
OTHER_GO="$(grep -A3 'GoTool@0' "$SCRIPTS_DIR/azure-devops/golang/abstracts/go.yaml" | grep -oE "version: *'[0-9.]+'" | grep -oE '[0-9][0-9.]*' | head -1)"
assert_true "it is the Go the other Go jobs run ($CODEQL_GO; azure-devops/golang/abstracts/go.yaml: $OTHER_GO)" \
  "[[ -n '$CODEQL_GO' && '$CODEQL_GO' == '$OTHER_GO' ]]"
echo ""

# ---------------------------------------------------------------------------
echo "4. Go is analysed"
# ---------------------------------------------------------------------------
# From 2026-08-21 the Go leg was waived, in a job of its own that announced the gap: the newest
# CodeQL bundle then, 2.26.3, carried a Go extractor built with go1.26, and that extractor refuses
# a newer language version -- `package requires newer Go version go1.27 (application built with
# go1.26)` -- while `database create` still exits 0 over the broken types. Every bundle from
# `codeql-bundle-v2.26.4` (2026-08-26) is built with go1.27, and Go is analysed again.
#
# These keep it so. A language dropped from a matrix looks identical to one nobody thought of, and
# reads as covered on every dashboard that counts green checks: leaving Go out again has to be a
# decision this file is edited for, not a line that goes missing.
assert_true "Go is in this repository's CodeQL matrix" \
  "grep -qE \"language: *\\[.*'go'\" '$SELF_WORKFLOW'"
assert_empty "no waiver job or expiry date is left behind" \
  "$(grep -nE 'go-analysis-waived|Go is not being analysed|Expires 20[0-9]{2}-' "$SELF_WORKFLOW" || true)"

# A leg that runs, fails and is forgiven is worse than one that is honestly absent. Comment lines
# are dropped before matching, for the reason `test-supply-chain.sh` gives about its own rules: a
# check that forbids a pattern must not be failed by a paragraph explaining it.
assert_empty "no continue-on-error hides a failing analysis" \
  "$(grep -n 'continue-on-error' "$SELF_WORKFLOW" | grep -vE '^[0-9]+: *#' || true)"

# The bundle `run.sh` installs -- GitLab CI, Azure DevOps, `make codeql` -- has to read the newest
# directive too, and it is the EXTRACTOR that refuses one, not the toolchain: a prebuilt binary, so
# each Go minor has a first bundle able to read it, the first whose `go/extractor/go.mod` names that
# Go. A module moving to a minor not listed here fails until someone looks the release up and adds
# the row:
#
#   gh api 'repos/github/codeql/contents/go/extractor/go.mod?ref=codeql-cli/vX.Y.Z' \
#     --jq .content | base64 -d | grep '^go '
declare -A FIRST_BUNDLE_FOR_GO=([1.24]='2.20.5' [1.25]='2.22.4' [1.26]='2.24.2' [1.27]='2.26.4')
NEWEST_MINOR="$(cut -d. -f1,2 <<< "$NEWEST_DIRECTIVE")"
PINNED_BUNDLE="$(grep -oE '^CODEQL_BUNDLE_PINNED_VERSION="codeql-bundle-v[0-9]+\.[0-9]+\.[0-9]+"' \
  "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
FIRST_BUNDLE="${FIRST_BUNDLE_FOR_GO[${NEWEST_MINOR:-none}]:-}"
assert_true "the first CodeQL bundle that reads go $NEWEST_MINOR, the newest directive here, is recorded" \
  "[[ -n '$FIRST_BUNDLE' ]]"
assert_true "the pinned bundle ($PINNED_BUNDLE) reads go $NEWEST_MINOR, as every bundle from $FIRST_BUNDLE does" \
  "[[ -n '$PINNED_BUNDLE' && -n '$FIRST_BUNDLE' ]] && version_le '$FIRST_BUNDLE' '$PINNED_BUNDLE'"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  echo "================================"
  exit 1
fi
echo "================================"
echo -e "${GREEN}Go module toolchain agreement holds${NC}"
