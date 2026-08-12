#!/usr/bin/env bash
# Regression test for global/scripts/shared/go-modcache.sh.
#
# The library decides where Go writes its module cache. Getting that wrong is
# not a cosmetic problem: a cache written under $TMPDIR consists of 0400 files
# inside 0500 directories, so whatever cleans the temp directory later cannot
# unlink any of it. The cases below pin both directions -- the redirect fires
# when GOPATH is inside $TMPDIR, and stays out of the way everywhere else, which
# is what keeps CI behaviour unchanged.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$SCRIPT_DIR/global/scripts/shared/go-modcache.sh"
EXIT_CODE=0
PASSED=0

echo "[test-go-tmpdir-modcache] testing Go module cache placement..." >&2

if [ ! -f "$LIB" ]; then
    echo "[test-go-tmpdir-modcache] FAIL: library not found at $LIB" >&2
    exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT

pass() { PASSED=$((PASSED + 1)); echo "[test-go-tmpdir-modcache] PASS: $1" >&2; }
fail() { EXIT_CODE=1; echo "[test-go-tmpdir-modcache] FAIL: $1" >&2; }

# Sources the library in a fresh `sh` with a controlled environment and echoes
# the resolved GOPATH and GOMODCACHE. `set -e` is on, matching the runners that
# source it, so a library that returns non-zero fails the case loudly.
resolve() {
    local workdir="$1" tmpdir="$2" home="$3" gopath="$4" gomodcache="$5" goflags="${6:--}"
    local prelude=""

    [ "$gopath" = "-" ] && prelude="$prelude unset GOPATH;" || prelude="$prelude export GOPATH='$gopath';"
    [ "$gomodcache" = "-" ] && prelude="$prelude unset GOMODCACHE;" || prelude="$prelude export GOMODCACHE='$gomodcache';"
    [ "$goflags" = "-" ] && prelude="$prelude unset GOFLAGS;" || prelude="$prelude export GOFLAGS='$goflags';"

    mkdir -p "$workdir"
    env -i PATH="$PATH" TMPDIR="$tmpdir" HOME="$home" sh -c "
        set -e
        cd '$workdir'
        $prelude
        . '$LIB'
        resolve_go_paths
        echo \"GOPATH=\$GOPATH\"
        echo \"GOMODCACHE=\${GOMODCACHE:-<unset>}\"
        echo \"GOFLAGS=\${GOFLAGS:-<unset>}\"
    " 2>/dev/null
}

check() {
    local description="$1" actual="$2" expected="$3"

    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description"
        echo "         expected: $expected" >&2
        echo "         actual:   $actual" >&2
    fi
}

FAKE_TMP="$SANDBOX/tmp"
FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_TMP" "$FAKE_HOME"

# --- GOPATH inside $TMPDIR: the redirect must fire ---------------------------
out="$(resolve "$FAKE_TMP/project" "$FAKE_TMP" "$FAKE_HOME" - -)"
check "defaults GOPATH to \$(pwd)/.go" \
      "$(echo "$out" | grep '^GOPATH=')" \
      "GOPATH=$FAKE_TMP/project/.go"
check "redirects GOMODCACHE out of \$TMPDIR" \
      "$(echo "$out" | grep '^GOMODCACHE=')" \
      "GOMODCACHE=$FAKE_HOME/go/pkg/mod"

# A trailing slash on TMPDIR must not defeat the prefix comparison.
out="$(resolve "$FAKE_TMP/project" "$FAKE_TMP/" "$FAKE_HOME" - -)"
check "redirects when \$TMPDIR carries a trailing slash" \
      "$(echo "$out" | grep '^GOMODCACHE=')" \
      "GOMODCACHE=$FAKE_HOME/go/pkg/mod"

# --- outside $TMPDIR: CI behaviour must be unchanged --------------------------
WORKSPACE="$SANDBOX/workspace"
out="$(resolve "$WORKSPACE" "$FAKE_TMP" "$FAKE_HOME" - -)"
check "leaves GOPATH at \$(pwd)/.go outside \$TMPDIR" \
      "$(echo "$out" | grep '^GOPATH=')" \
      "GOPATH=$WORKSPACE/.go"
check "leaves GOMODCACHE unset outside \$TMPDIR" \
      "$(echo "$out" | grep '^GOMODCACHE=')" \
      "GOMODCACHE=<unset>"

# A directory whose name merely starts with the temp path must not be caught.
NEIGHBOUR="${FAKE_TMP}-sibling"
out="$(resolve "$NEIGHBOUR" "$FAKE_TMP" "$FAKE_HOME" - -)"
check "does not treat a sibling path sharing the \$TMPDIR prefix as inside it" \
      "$(echo "$out" | grep '^GOMODCACHE=')" \
      "GOMODCACHE=<unset>"

# --- explicit caller choices win ---------------------------------------------
out="$(resolve "$FAKE_TMP/project" "$FAKE_TMP" "$FAKE_HOME" - "$FAKE_TMP/explicit")"
check "respects an explicit GOMODCACHE" \
      "$(echo "$out" | grep '^GOMODCACHE=')" \
      "GOMODCACHE=$FAKE_TMP/explicit"

out="$(resolve "$FAKE_TMP/project" "$FAKE_TMP" "$FAKE_HOME" "$SANDBOX/explicit-gopath" -)"
check "respects an explicit GOPATH" \
      "$(echo "$out" | grep '^GOPATH=')" \
      "GOPATH=$SANDBOX/explicit-gopath"

# --- degenerate environment must not abort the runner ------------------------
out="$(resolve "$FAKE_TMP/project" "$FAKE_TMP" "" - -)"
check "leaves GOMODCACHE alone when \$HOME is unset" \
      "$(echo "$out" | grep '^GOMODCACHE=')" \
      "GOMODCACHE=<unset>"
check "still resolves GOPATH when \$HOME is unset" \
      "$(echo "$out" | grep '^GOPATH=')" \
      "GOPATH=$FAKE_TMP/project/.go"

# --- the module cache must stay removable ------------------------------------
# The default GOPATH puts the cache inside the workspace, which is fine only while the workspace
# is thrown away after every job. A persistent runner reuses it, and the next checkout then fails
# to clean a read-only cache with EACCES -- before any job on that machine starts.
out="$(resolve "$SANDBOX/project" "$FAKE_TMP" "$FAKE_HOME" - -)"
check "asks Go for a writable module cache" \
      "$(echo "$out" | grep '^GOFLAGS=')" \
      "GOFLAGS=-modcacherw"

out="$(resolve "$SANDBOX/project" "$FAKE_TMP" "$FAKE_HOME" - - "-mod=readonly")"
check "appends to an existing GOFLAGS rather than replacing it" \
      "$(echo "$out" | grep '^GOFLAGS=')" \
      "GOFLAGS=-mod=readonly -modcacherw"

out="$(resolve "$SANDBOX/project" "$FAKE_TMP" "$FAKE_HOME" - - "-modcacherw")"
check "does not repeat the flag when it is already set" \
      "$(echo "$out" | grep '^GOFLAGS=')" \
      "GOFLAGS=-modcacherw"

# --- the property the whole library exists for -------------------------------
# Reproduce Go's own permissions and prove the placement decision is what makes
# the difference between a removable cache and a permanent one.
mkdir -p "$SANDBOX/perm/pkg/mod/example.com/dep@v1.0.0"
echo "package dep" > "$SANDBOX/perm/pkg/mod/example.com/dep@v1.0.0/dep.go"
chmod 0400 "$SANDBOX/perm/pkg/mod/example.com/dep@v1.0.0/dep.go"
chmod 0500 "$SANDBOX/perm/pkg/mod/example.com/dep@v1.0.0"
if rm -rf "$SANDBOX/perm/pkg/mod" 2>/dev/null && [ ! -d "$SANDBOX/perm/pkg/mod" ]; then
    fail "a Go-permissioned module cache resists rm -rf (premise of this library)"
else
    pass "a Go-permissioned module cache resists rm -rf (premise of this library)"
fi

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "[test-go-tmpdir-modcache] all $PASSED module cache placement tests passed" >&2
fi

exit $EXIT_CODE
