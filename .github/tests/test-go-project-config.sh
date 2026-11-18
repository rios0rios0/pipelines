#!/usr/bin/env bash
# How the Go runners load a project's `config.sh`, the file that sets GOPRIVATE and the git settings
# that authenticate private module fetches.
#
# A `config.sh` hands git its settings in one of two ways, and every place that loads it must work
# with both:
#   - "global": `git config --global`, everywhere. What older files do. On a developer's machine it
#     wrote a URL rewrite carrying a token, or an `Authorization` header with an empty one, into
#     `~/.gitconfig`, which outlived the run.
#   - "scoped": `git config --global` on a CI runner only (TF_BUILD, GITHUB_ACTIONS or GITLAB_CI),
#     where later steps of the job need what it wrote; anywhere else it exports the settings
#     (`GIT_CONFIG_COUNT`/`KEY`/`VALUE`) to the shell that sourced it, and writes nothing.
#
# Asserts, with `codeql` replaced by a stub whose `database create` records what the Go build it
# would run can see:
#   1. a local `make codeql` sources either kind in the process of the build, which sees GOPRIVATE
#      and the rewrite, and the developer's global configuration is left as it was -- a "global"
#      file's write goes to a file of the scan, which reads the developer's own settings through an
#      include and is removed afterwards
#   2. on a CI runner the scan writes no such file: a "global" or a "scoped" file writes the global
#      configuration, where the job's later steps read it
#   3. the Go init step, a process of its own on CI, leaves either kind's settings in the global
#      configuration for the steps after it
#   4. the GitLab CI SAM delivery sources `config.sh` into the shell that runs `sam build`, so a file
#      without an executable bit works and its exports reach the build

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
CODEQL_RUN="$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh"
INIT_RUN="$SCRIPTS_DIR/global/scripts/languages/golang/init/run.sh"
SAM_TEMPLATE="$SCRIPTS_DIR/gitlab/golang/stages/40-delivery/sam.yaml"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (expected '$expected', got '$actual')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

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

# What every fixture `config.sh` configures, and what every check reads back.
REWRITE_KEY='url.https://mirror.example.invalid/private.insteadOf'
REWRITE_VALUE='https://example.invalid/private'
PRIVATE='example.invalid/private'

# write_config <dir> <global|scoped>: a `config.sh` of that kind, without an executable bit.
write_config() {
  case "$2" in
    global)
      cat > "$1/config.sh" << EOF
# shellcheck shell=sh
export GOPRIVATE='$PRIVATE'
git config --global '$REWRITE_KEY' '$REWRITE_VALUE'
EOF
      ;;
    scoped)
      cat > "$1/config.sh" << EOF
# shellcheck shell=sh
export GOPRIVATE='$PRIVATE'
if [ -n "\${TF_BUILD:-}\${GITHUB_ACTIONS:-}\${GITLAB_CI:-}" ]; then
  git config --global '$REWRITE_KEY' '$REWRITE_VALUE'
else
  index="\${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_\$index=$REWRITE_KEY" "GIT_CONFIG_VALUE_\$index=$REWRITE_VALUE"
  export GIT_CONFIG_COUNT="\$((index + 1))"
fi
EOF
      ;;
  esac
  chmod 0644 "$1/config.sh"
}

# The stub CodeQL. `database create` records what a Go build it started would see -- GOPRIVATE, the
# URL rewrite as git resolves it, and the global configuration file git writes to -- and makes the
# database directory; `database analyze` writes a report with no finding.
STUB_BIN="$TEST_DIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/codeql" << STUB
#!/usr/bin/env sh
command="\$1 \$2"
shift 2
case "\$command" in
  'database create')
    for argument in "\$@"; do database="\$argument"; done
    printf '%s\n' "\${GOPRIVATE:-}" > "\$CODEQL_STUB_RECORD/goprivate"
    git config --get-all '$REWRITE_KEY' > "\$CODEQL_STUB_RECORD/rewrite" 2> /dev/null
    git config --get user.name > "\$CODEQL_STUB_RECORD/user" 2> /dev/null
    printf '%s\n' "\${GIT_CONFIG_GLOBAL:-}" > "\$CODEQL_STUB_RECORD/global-file"
    mkdir -p "\$database"
    ;;
  'database analyze')
    for argument in "\$@"; do
      case "\$argument" in --output=*) output="\${argument#--output=}" ;; esac
    done
    printf '%s\n' '{"runs":[{"results":[]}]}' > "\$output"
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/codeql"

# scan <project> <env assignment>...: runs the CodeQL runner for Go in <project>, as on a developer's
# machine unless an assignment says otherwise, with "$TEST_DIR/developer.gitconfig" as the global
# configuration. Prints the directory the stub recorded into; the exit status goes to its `status`.
scan() {
  local project="$1" record status=0
  shift
  record="$(mktemp -d "$TEST_DIR/record.XXXXXX")" || exit 1
  (
    cd "$project" || exit 1
    env -u CI -u TF_BUILD -u GITHUB_ACTIONS -u GITLAB_CI -u CODEQL_RAM -u GIT_CONFIG_COUNT \
      HOME="$TEST_DIR/home" PATH="$STUB_BIN:$PATH" SCRIPTS_DIR="$SCRIPTS_DIR" \
      GIT_CONFIG_GLOBAL="$TEST_DIR/developer.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
      CODEQL_STUB_RECORD="$record" "$@" "$CODEQL_RUN" go
  ) > "$record/output" 2>&1 || status=$?
  echo "$status" > "$record/status"
  echo "$record"
}

record_of() { cat "$1/$2" 2> /dev/null; }

# A developer's global configuration: an identity the scan must keep reading.
developer_config() { printf '[user]\n\tname = Developer\n' > "$TEST_DIR/developer.gitconfig"; }

echo "Testing how the Go runners load a project's config.sh..."

for kind in global scoped; do
  echo ""
  echo "Test 1 ($kind): a local make codeql sources config.sh in the process of the build"
  # given
  PROJECT="$TEST_DIR/local-$kind"
  mkdir -p "$PROJECT"
  write_config "$PROJECT" "$kind"
  developer_config
  BEFORE="$(cksum < "$TEST_DIR/developer.gitconfig")"

  # when
  RECORD="$(scan "$PROJECT")"

  # then
  [ "$(record_of "$RECORD" status)" = "0" ] || cat "$RECORD/output"
  assert_equals "the scan succeeds" "0" "$(record_of "$RECORD" status)"
  assert_equals "the build sees GOPRIVATE" "$PRIVATE" "$(record_of "$RECORD" goprivate)"
  assert_equals "the build sees the URL rewrite" "$REWRITE_VALUE" "$(record_of "$RECORD" rewrite)"
  assert_equals "the build still reads the developer's own settings" "Developer" "$(record_of "$RECORD" user)"
  assert_equals "the developer's global configuration is left as it was" "$BEFORE" "$(cksum < "$TEST_DIR/developer.gitconfig")"
  GLOBAL_FILE="$(record_of "$RECORD" global-file)"
  assert_true "the build's global configuration is a file of the scan" \
    "[ -n '$GLOBAL_FILE' ] && [ '$GLOBAL_FILE' != '$TEST_DIR/developer.gitconfig' ]"
  assert_true "which the scan removed" "[ ! -e '$GLOBAL_FILE' ]"

  echo ""
  echo "Test 2 ($kind): on a CI runner the global configuration is the job's, and keeps the settings"
  # given
  PROJECT="$TEST_DIR/ci-$kind"
  mkdir -p "$PROJECT"
  write_config "$PROJECT" "$kind"
  : > "$TEST_DIR/developer.gitconfig"

  # when
  RECORD="$(scan "$PROJECT" TF_BUILD=True)"

  # then
  assert_equals "the scan succeeds" "0" "$(record_of "$RECORD" status)"
  assert_equals "the build sees the URL rewrite" "$REWRITE_VALUE" "$(record_of "$RECORD" rewrite)"
  assert_equals "the build writes the job's global configuration" "$TEST_DIR/developer.gitconfig" "$(record_of "$RECORD" global-file)"
  assert_equals "where the job's later steps read the rewrite" "$REWRITE_VALUE" \
    "$(GIT_CONFIG_GLOBAL="$TEST_DIR/developer.gitconfig" git config --global --get-all "$REWRITE_KEY")"

  echo ""
  echo "Test 3 ($kind): the Go init step leaves the settings for the CI steps after it"
  # given
  PROJECT="$TEST_DIR/init-$kind"
  mkdir -p "$PROJECT"
  write_config "$PROJECT" "$kind"
  : > "$TEST_DIR/job.gitconfig"

  # when
  STATUS=0
  (
    cd "$PROJECT" || exit 1
    env -u CI -u GITHUB_ACTIONS -u GITLAB_CI -u GIT_CONFIG_COUNT -u SCRIPTS_DIR TF_BUILD=True \
      GIT_CONFIG_GLOBAL="$TEST_DIR/job.gitconfig" GIT_CONFIG_NOSYSTEM=1 "$INIT_RUN"
  ) > "$TEST_DIR/init.log" 2>&1 || STATUS=$?

  # then
  [ "$STATUS" -eq 0 ] || cat "$TEST_DIR/init.log"
  assert_equals "the init step succeeds" "0" "$STATUS"
  assert_equals "a later step, a process of its own, sees the URL rewrite" "$REWRITE_VALUE" \
    "$(GIT_CONFIG_GLOBAL="$TEST_DIR/job.gitconfig" git config --global --get-all "$REWRITE_KEY")"
done

echo ""
echo "Test 4: the GitLab CI SAM delivery sources config.sh into the shell that runs sam build"
# The step is read from the template with mikefarah/yq, resolved the way every script here resolves it.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"
. "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"
YQ=""
if resolve_yq "$TEST_DIR/yqbin"; then
  # given
  STEP="$("$YQ" eval '.[".delivery"].script[0]' "$SAM_TEMPLATE")"
  PROJECT="$TEST_DIR/sam"
  mkdir -p "$PROJECT"
  write_config "$PROJECT" scoped
  : > "$TEST_DIR/job.gitconfig"

  # when: the step, then what `sam build` would see, in one POSIX shell as GitLab runs a job's script
  SEEN="$(
    cd "$PROJECT" || exit 1
    env -u CI -u TF_BUILD -u GITHUB_ACTIONS -u GIT_CONFIG_COUNT GITLAB_CI=true \
      GIT_CONFIG_GLOBAL="$TEST_DIR/job.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
      sh -c "$STEP"' && printf "%s|%s\n" "$GOPRIVATE" "$(git config --get-all '"$REWRITE_KEY"')"' 2>&1
  )"

  # then
  assert_equals "the step sources config.sh, with no executable bit, and the build sees what it set" \
    "$PRIVATE|$REWRITE_VALUE" "$SEEN"

  # given: a project without config.sh
  EMPTY="$TEST_DIR/empty"
  mkdir -p "$EMPTY"

  # when
  STATUS=0
  (
    cd "$EMPTY" || exit 1
    sh -c "$STEP"
  ) > /dev/null 2>&1 || STATUS=$?

  # then
  assert_equals "a project without config.sh passes the step" "0" "$STATUS"
else
  echo -e "${RED}  FAIL: could not resolve mikefarah/yq, so the SAM step could not be read${NC}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
