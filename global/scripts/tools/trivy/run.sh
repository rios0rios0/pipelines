#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="trivy" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

jsonFile="$(pwd)/$REPORT_PATH/trivy.json"
sarifFile="$(pwd)/$REPORT_PATH/trivy.sarif"

# Install Trivy if not already available.
#
# The upstream `install.sh` resolves the `latest` Trivy release by
# calling GitHub's releases API. That call is rate-limited and
# occasionally returns an empty body (logged by the helper as
# `aquasecurity/trivy crit unable to find ''`), in which case the
# installer aborts WITHOUT dropping the binary on disk. The subsequent
# `trivy ...` invocations below would then exit `127` (`trivy: not
# found`) with no clear pointer back to the install step. Retry up to
# 3 times with linear backoff and verify the binary actually landed
# before continuing -- if the install never succeeds, fail loudly.
if ! command -v trivy > /dev/null 2>&1; then
  echo "Downloading Trivy..."
  attempt=1
  maxAttempts=3
  while [ $attempt -le $maxAttempts ]; do
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /tmp || true
    if [ -x /tmp/trivy ]; then
      break
    fi
    if [ $attempt -lt $maxAttempts ]; then
      sleepSeconds=$((attempt * 5))
      echo "Trivy install attempt $attempt failed (binary not at /tmp/trivy); retrying in ${sleepSeconds}s..."
      sleep $sleepSeconds
    fi
    attempt=$((attempt + 1))
  done
  if [ ! -x /tmp/trivy ]; then
    echo "ERROR: Trivy install failed after $maxAttempts attempts. The upstream installer at https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh likely hit a GitHub API rate limit on the 'latest' tag lookup. Re-run the pipeline or pin a Trivy version explicitly." >&2
    exit 1
  fi
  export PATH="/tmp:$PATH"
fi

# Use default ignore file if the project doesn't provide one
ignoreFileExists=true
if [ ! -f ".trivyignore" ]; then
  ignoreFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/trivy/.trivyignore"
  cp "$defaultFile" .
fi

echo "Running Trivy IaC misconfiguration scan..."
# Primary output is JSON — always works and aligns with the other tool
# scripts (`trivy-sca.json`, `govulncheck.json`, `semgrep.json`, etc.).
#
# `--tf-exclude-downloaded-modules` keeps Trivy from re-flagging vendored
# Terraform modules that the parser resolves through `module "x" { source = "git@..." }`
# blocks. Each upstream module owns its security posture (runs its own
# `make sast`, ships its own `.trivyignore`); without this flag the
# consumer scan re-flags every unresolvable `var.*` default in the
# vendored `main.tf` and consumers have to mirror every upstream
# `.trivyignore` (Trivy reads `.trivyignore` only at the scan root, not
# from vendored subdirs) — producing duplicate, drift-prone suppression
# lists. The flag does NOT silence findings against module references
# inside the consumer's own configuration (resource attributes, variable
# wiring, etc.), only the bodies of the downloaded modules themselves.
trivy_tf_exclude_flag=""
if trivy filesystem --help 2>/dev/null | grep -q -- '--tf-exclude-downloaded-modules'; then
  trivy_tf_exclude_flag="--tf-exclude-downloaded-modules"
else
  echo "Installed Trivy does not support --tf-exclude-downloaded-modules; continuing without it."
fi

trivy filesystem \
  --scanners misconfig \
  ${trivy_tf_exclude_flag:+$trivy_tf_exclude_flag} \
  --format json \
  --output "$jsonFile" \
  --exit-code 1 \
  "$(pwd)" || EXIT_CODE=$?

# SARIF is produced via `trivy convert`. Trivy's SARIF writer panics with
# a nil-URL `SIGSEGV` in `pkg/report/sarif.go:103` when a Terraform
# `source` pin references an SSH remote like `git@host:path/repo?ref=x`
# because Go's `net/url` rejects the colon in the first path segment and
# `SarifWriter.addSarifResult` dereferences the nil result. To sidestep
# the panic, every `git@host:path` string in a *copy* of `trivy.json` is
# rewritten to the equivalent valid RFC 3986 URL `ssh://git@host/path`
# before conversion — `trivy.json` itself stays untouched so it remains
# the authoritative artifact consumers archive or parse. `jq`'s `walk`
# traverses the full JSON tree so finding locations, artifact paths, and
# any other embedded URI reference are all normalized in one pass. `walk`
# is redefined inline for compatibility with `jq` versions older than
# `1.6` (where the builtin was introduced). The fallback `|| echo` is
# kept as a safety net for unrelated convert failures.
sanitizedJsonFile="$(pwd)/$REPORT_PATH/trivy.sanitized.json"
convertInput="$jsonFile"
if [ -f "$jsonFile" ] && command -v jq > /dev/null 2>&1; then
  echo "Sanitizing SSH-style module URIs in a Trivy JSON copy before SARIF conversion..."
  if jq '
    def walk(f):
      . as $in
      | if type == "object" then
          reduce keys[] as $key
            ({}; . + { ($key): ($in[$key] | walk(f)) }) | f
        elif type == "array" then
          map(walk(f)) | f
        else
          f
        end;
    walk(if type == "string" and test("^git@[^:]+:") then sub("^git@(?<h>[^:]+):(?<p>.+)$"; "ssh://git@\(.h)/\(.p)") else . end)
  ' "$jsonFile" > "$sanitizedJsonFile"; then
    convertInput="$sanitizedJsonFile"
  else
    rm -f "$sanitizedJsonFile"
    echo "Trivy JSON sanitization failed; falling back to original trivy.json for SARIF conversion."
  fi
else
  echo "Skipping Trivy JSON sanitization; jq is unavailable or trivy.json was not created."
fi

echo "Converting Trivy JSON report to SARIF..."
trivy convert \
  --format sarif \
  --output "$sarifFile" \
  "$convertInput" || echo "SARIF conversion failed; trivy.json is authoritative."

# Remove the intermediate sanitized copy; trivy.json remains the authoritative artifact.
rm -f "$sanitizedJsonFile"

if [ "$ignoreFileExists" = false ]; then
  rm -f .trivyignore
fi

echo "Trivy analysis complete. Results written to: $jsonFile (and $sarifFile when convertible)."
exit ${EXIT_CODE:-0}
