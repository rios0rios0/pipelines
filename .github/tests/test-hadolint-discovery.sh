#!/usr/bin/env bash

# Regression test for the Dockerfile discovery in `global/scripts/tools/hadolint/run.sh`.
#
# Why it exists: discovery matched `-name "Dockerfile*"` and nothing else, so a Dockerfile named
# `<name>.Dockerfile` was never linted. That is the name every delivery template here builds --
# `.ci/stages/40-delivery/app.Dockerfile`, on GitHub and on Azure DevOps -- so a project laid out
# the way those templates require shipped its image from a Dockerfile Hadolint had never read.
# Where that was its only Dockerfile, the job printed "No Dockerfiles found, skipping Hadolint
# analysis." and passed, and nothing in that line gives the miss away: it is also the honest
# answer for a project without a Dockerfile.
#
# Asserts:
#   * `Dockerfile`, `Dockerfile.<variant>`, `<name>.Dockerfile` and `<name>.dockerfile` are linted
#   * every Dockerfile path a delivery template builds is linted, read from the templates
#     themselves, so renaming either side fails here instead of quietly emptying the lint
#   * a directory named like one (`Dockerfiles/`) is not, nor is BuildKit's per-Dockerfile
#     `<name>.dockerignore` -- hadolint exits 1 on both, the first with "inappropriate type
#     (is a directory)", the second with a DL1000 parse error
#   * nothing under `.git/`, `node_modules/`, `vendor/` or `.codeql-db/` is linted
#   * a project with no Dockerfile still skips, exits 0 and writes an empty SARIF report
#
# Hadolint is a stub that records its argv: this is about which files reach it, not about what it
# finds in them.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SCRIPTS_DIR/global/scripts/tools/hadolint/run.sh"

PASS=0
FAIL=0
pass() { echo "[test-hadolint-discovery] PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "[test-hadolint-discovery] FAIL: $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# A HOME of its own: `cleanup.sh` puts `$HOME/.local/bin` first on PATH, so this stub wins over
# any real hadolint on the machine, and the version it reports is the one HADOLINT_VERSION pins
# below, so `run.sh` never reaches its download.
mkdir -p "$WORK/home/.local/bin" || exit 1
cat > "$WORK/home/.local/bin/hadolint" <<'STUB'
#!/usr/bin/env sh
if [ "$1" = "--version" ]; then
  echo "Haskell Dockerfile Linter 0.0.0-stub"
  exit 0
fi
printf '%s\n' "$@" > "$HADOLINT_ARGV"
echo '{"version":"2.1.0","runs":[]}'
STUB
chmod +x "$WORK/home/.local/bin/hadolint"

# Runs `run.sh` in the project at $1, prints its combined output and returns its exit code.
run_discovery() {
  rm -f "$WORK/argv"
  (
    cd "$1" || exit 1
    HOME="$WORK/home" HADOLINT_VERSION='0.0.0-stub' HADOLINT_ARGV="$WORK/argv" \
      SCRIPTS_DIR="$SCRIPTS_DIR" REPORT_PATH='' "$SCRIPT" 2>&1
  )
}

# Whether the stub was handed exactly the path $1.
linted() { [ -f "$WORK/argv" ] && grep -qxF "$1" "$WORK/argv"; }

# given: a project holding every name a Dockerfile goes by, and every look-alike that is not one
PROJECT="$WORK/project"
LINTED=(
  'Dockerfile'
  'Dockerfile.dev'
  'tools/load-test.Dockerfile'
  'plugins/rails/Rails.dockerfile'
  'Dockerfiles/base.Dockerfile'
)
# The templates are the authority on where the delivery Dockerfile lives. An empty list would
# make every assertion over it pass vacuously, so it is checked for before it is trusted.
mapfile -t DELIVERY < <(
  grep -rhoE '\.ci/stages/40-delivery/[A-Za-z0-9_.-]+' \
    "$SCRIPTS_DIR/github" "$SCRIPTS_DIR/gitlab" "$SCRIPTS_DIR/azure-devops" \
    | grep -iE 'dockerfile$' | sort -u
)
NOT_LINTED=(
  'Dockerfile.dockerignore'
  '.ci/stages/40-delivery/app.Dockerfile.dockerignore'
  '.git/Dockerfile'
  'node_modules/some-package/app.Dockerfile'
  'vendor/some-module/Dockerfile'
  '.codeql-db/src/app.Dockerfile'
)
for path in "${LINTED[@]}" "${DELIVERY[@]}" "${NOT_LINTED[@]}"; do
  mkdir -p "$PROJECT/$(dirname "$path")" || exit 1
  echo 'FROM scratch' > "$PROJECT/$path"
done

# when
OUT="$(run_discovery "$PROJECT")"
STATUS=$?

# then
if [ "$STATUS" -eq 0 ]; then
  pass "a project with Dockerfiles runs the linter and exits 0 on a clean result"
else
  fail "run.sh exited $STATUS: $OUT"
fi
if [ "${#DELIVERY[@]}" -gt 0 ]; then
  pass "the delivery templates name ${#DELIVERY[@]} Dockerfile path(s): ${DELIVERY[*]}"
else
  fail "no '.ci/stages/40-delivery/*Dockerfile' path found in github/, gitlab/ or azure-devops/ -- the delivery assertions below would prove nothing"
fi
for path in "${LINTED[@]}"; do
  if linted "$PROJECT/$path"; then
    pass "linted: $path"
  else
    fail "not linted: $path (hadolint got: $(tr '\n' ' ' < "$WORK/argv" 2>/dev/null))"
  fi
done
for path in "${DELIVERY[@]}"; do
  if linted "$PROJECT/$path"; then
    pass "linted, as the delivery stage builds it: $path"
  else
    fail "the delivery stage builds $path, and Hadolint never sees it"
  fi
done
for path in "${NOT_LINTED[@]}"; do
  if linted "$PROJECT/$path"; then
    fail "linted, and should not be: $path"
  else
    pass "not linted: $path"
  fi
done
if linted "$PROJECT/Dockerfiles"; then
  fail "the directory Dockerfiles/ was handed to hadolint, which exits 1 on a directory"
else
  pass "a directory named Dockerfiles/ is not handed to hadolint"
fi

# given: a project whose only look-alikes are a directory and an ignore file
EMPTY="$WORK/empty"
mkdir -p "$EMPTY/Dockerfiles" || exit 1
echo 'node_modules' > "$EMPTY/Dockerfile.dockerignore"

# when
OUT="$(run_discovery "$EMPTY")"
STATUS=$?

# then: the skip still reads as a skip, and the report the upload step expects is still written
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -q 'No Dockerfiles found'; then
  pass "a project without a Dockerfile skips and exits 0"
else
  fail "expected the skip and exit 0, got exit $STATUS: $OUT"
fi
if [ ! -f "$WORK/argv" ]; then
  pass "hadolint is not run when nothing was found"
else
  fail "hadolint ran with: $(tr '\n' ' ' < "$WORK/argv")"
fi
if grep -q '"results": \[\]' "$EMPTY/build/reports/hadolint/hadolint.sarif" 2>/dev/null; then
  pass "the skip still writes an empty SARIF report"
else
  fail "no empty SARIF report at build/reports/hadolint/hadolint.sarif"
fi

echo "[test-hadolint-discovery] $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
