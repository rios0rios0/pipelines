#!/usr/bin/env bash
# Validation script for the license ids of the Go CycloneDX generator's BOM.
#
# cyclonedx-gomod writes the license its detector matched into `license.id` verbatim, and the
# detector names a DEPRECATED SPDX license after its license-list file: `deprecated_GPL-2.0+`, an id
# no SPDX list holds. Dependency-Track validates the BOM against the CycloneDX schema, whose
# `license.id` enumerates the SPDX list, and on 2026-11-26 it refused a consumer's whole BOM with
# HTTP 400 over one module, github.com/golang/freetype.
#
# `global/scripts/languages/golang/cyclonedx/run.sh` therefore runs the license helper
# (`cyclonedx/licenses`, Go, built from this checkout) on every BOM it writes. Its rules are
# unit-tested in Go (`make test ONLY=go-helpers`); this suite proves the WIRING: every mode the
# script picks hands its BOM to the helper, the BOM that reaches the uploader is the rewritten one,
# a BOM with nothing to rewrite is left byte for byte, and a BOM the helper cannot read fails the
# job instead of being uploaded as it is.
#
# `cyclonedx-gomod` itself is not invoked: a stub writes a fixture BOM at the `-output` path.

set -euo pipefail

echo "=== Testing the Go CycloneDX generator's license ids ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CYCLONEDX_SCRIPT="$REPO_ROOT/global/scripts/languages/golang/cyclonedx/run.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
  local result=$1
  local message=$2
  if [ "$result" -eq 0 ]; then
    echo -e "${GREEN}  PASS: $message${NC}"
    ((TESTS_PASSED++)) || true
  else
    echo -e "${RED}  FAIL: $message${NC}"
    ((TESTS_FAILED++)) || true
  fi
}

REAL_GO="$(command -v go)" || {
  echo "Go is required: the generator builds its license helper from this checkout" >&2
  exit 1
}

TEST_DIR="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# A cyclonedx-gomod that writes $BOM_FIXTURE at its -output path, and a `go` that answers
# `go env GOPATH`, swallows `go install` and passes the helper's build to the real Go.
FAKE_GOPATH="$TEST_DIR/gopath"
mkdir -p "$FAKE_GOPATH/bin" "$TEST_DIR/shim"

cat > "$FAKE_GOPATH/bin/cyclonedx-gomod" <<'STUB'
#!/usr/bin/env bash
previous=""
for arg in "$@"; do
  if [ "$previous" = "-output" ]; then
    mkdir -p "$(dirname "$arg")"
    cp "$BOM_FIXTURE" "$arg"
  fi
  previous="$arg"
done
STUB
chmod +x "$FAKE_GOPATH/bin/cyclonedx-gomod"

cat > "$TEST_DIR/shim/go" <<STUB
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "env GOPATH") echo "$FAKE_GOPATH" ;;
  "install "*) exit 0 ;;
  *) exec "$REAL_GO" "\$@" ;;
esac
STUB
chmod +x "$TEST_DIR/shim/go"

# The shape cyclonedx-gomod v1.12.0 writes, cut down: one module whose license id is listed, the
# freetype module whose id came out under its license-list file name, and an id no SPDX list holds.
FIXTURE="$TEST_DIR/bom.fixture.json"
cat > "$FIXTURE" <<'JSON'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "components": [
    {
      "name": "github.com/go-pdf/fpdf",
      "evidence": {
        "licenses": [
          {
            "license": {
              "id": "MIT"
            }
          }
        ]
      }
    },
    {
      "name": "github.com/golang/freetype",
      "evidence": {
        "licenses": [
          {
            "license": {
              "id": "deprecated_GPL-2.0+"
            }
          }
        ]
      }
    },
    {
      "name": "example.test/private",
      "evidence": {
        "licenses": [
          {
            "license": {
              "id": "LicenseRef-example"
            }
          }
        ]
      }
    }
  ]
}
JSON

# What Dependency-Track must receive: the same bytes but for the two ids it would refuse.
EXPECTED="$TEST_DIR/bom.expected.json"
sed -e 's/"id": "deprecated_GPL-2.0+"/"id": "GPL-2.0+"/' \
  -e 's/"id": "LicenseRef-example"/"name": "LicenseRef-example"/' "$FIXTURE" > "$EXPECTED"

# Run the generator inside a throwaway module laid out by the caller, with a BOM fixture.
# Usage: run_generator <workdir> <fixture>
run_generator() {
  local workdir="$1"
  local fixture="$2"
  (
    cd "$workdir" || exit 1
    PATH="$TEST_DIR/shim:$PATH" \
    GOPATH="$FAKE_GOPATH" \
    SCRIPTS_DIR="$REPO_ROOT" \
    BOM_FIXTURE="$fixture" \
    REPORT_PATH="build/reports" \
    PREFIX="" \
      sh "$CYCLONEDX_SCRIPT" > "$workdir/stdout.log" 2>&1
  )
}

new_module() {
  local workdir
  workdir="$(mktemp -d "$TEST_DIR/module-XXXXXX")" || exit 1
  printf 'module example.test\n\ngo 1.24\n' > "$workdir/go.mod"
  echo "$workdir"
}

# Usage: assert_rewritten <workdir> <mode description>
assert_rewritten() {
  local workdir="$1"
  local mode="$2"
  if diff -u "$EXPECTED" "$workdir/build/reports/bom.json" > "$workdir/diff.log" 2>&1; then
    print_result 0 "$mode: the BOM differs from the generator's only in the two refused ids"
  else
    print_result 1 "$mode: unexpected BOM: $(cat "$workdir/diff.log") $(cat "$workdir/stdout.log")"
  fi
}

# =============================================================================
# Test 1: `app` mode (one main package) rewrites the ids Dependency-Track refuses
# =============================================================================
echo "TEST 1: 'app' mode hands its BOM to the license helper"
workdir="$(new_module)"
mkdir -p "$workdir/cmd"
echo 'package main' > "$workdir/cmd/main.go"
if run_generator "$workdir" "$FIXTURE"; then
  print_result 0 "the generator exits 0"
else
  print_result 1 "the generator failed: $(cat "$workdir/stdout.log")"
fi
assert_rewritten "$workdir" "app"

if grep -q 'components\[1\].evidence.licenses\[0\].license: "deprecated_GPL-2.0+" is the SPDX id "GPL-2.0+"' \
  "$workdir/stdout.log"; then
  print_result 0 "the log names the restored id and where it was"
else
  print_result 1 "the log does not name the restored id: $(cat "$workdir/stdout.log")"
fi

if grep -q '"LicenseRef-example" is not an id of SPDX license list v1.0-3.27.0; wrote it as the license name' \
  "$workdir/stdout.log"; then
  print_result 0 "the log names the id written as a license name"
else
  print_result 1 "the log does not name the id written as a name: $(cat "$workdir/stdout.log")"
fi

# =============================================================================
# Test 2: both `mod` modes do the same
# =============================================================================
echo "TEST 2: both 'mod' modes hand their BOM to the license helper"
workdir="$(new_module)"
mkdir -p "$workdir/pkg" "$workdir/cmd"
echo 'package example' > "$workdir/pkg/example.go"
echo 'package main' > "$workdir/cmd/main.go"
run_generator "$workdir" "$FIXTURE" || true
assert_rewritten "$workdir" "mod (pkg/ directory)"

workdir="$(new_module)"
mkdir -p "$workdir/cmd/worker"
echo 'package main' > "$workdir/cmd/main.go"
echo 'package main' > "$workdir/cmd/worker/main.go"
run_generator "$workdir" "$FIXTURE" || true
assert_rewritten "$workdir" "mod (two main packages)"

# =============================================================================
# Test 3: a BOM with nothing to rewrite is left byte for byte
# =============================================================================
echo "TEST 3: a BOM whose ids are all listed is left as the generator wrote it"
workdir="$(new_module)"
mkdir -p "$workdir/cmd"
echo 'package main' > "$workdir/cmd/main.go"
run_generator "$workdir" "$EXPECTED" || true
if cmp -s "$EXPECTED" "$workdir/build/reports/bom.json"; then
  print_result 0 "the BOM is byte-identical to the generator's"
else
  print_result 1 "a BOM with nothing to rewrite was changed: $(cat "$workdir/stdout.log")"
fi

if grep -q 'license id(s) checked against SPDX license list v1.0-3.27.0, 0 rewritten' "$workdir/stdout.log"; then
  print_result 0 "the log says nothing was rewritten"
else
  print_result 1 "the summary is missing: $(cat "$workdir/stdout.log")"
fi

# =============================================================================
# Test 4: a BOM the helper cannot read fails the job instead of being uploaded
# =============================================================================
echo "TEST 4: a BOM that is not JSON fails the generator"
broken="$TEST_DIR/bom.broken.json"
printf '{"components": [' > "$broken"
workdir="$(new_module)"
mkdir -p "$workdir/cmd"
echo 'package main' > "$workdir/cmd/main.go"
if run_generator "$workdir" "$broken"; then
  print_result 1 "expected a non-zero exit for a BOM that is not JSON"
else
  print_result 0 "the generator exits non-zero"
fi

if grep -q 'bom.json: the BOM is not a JSON document' "$workdir/stdout.log"; then
  print_result 0 "the failure names the BOM and why"
else
  print_result 1 "the failure message is missing: $(cat "$workdir/stdout.log")"
fi

if cmp -s "$broken" "$workdir/build/reports/bom.json"; then
  print_result 0 "the BOM is left as the generator wrote it"
else
  print_result 1 "the helper changed a BOM it could not read"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
