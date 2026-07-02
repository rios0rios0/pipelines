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
  installerLog="/tmp/trivy-install.log"
  installerStatus=0
  while [ $attempt -le $maxAttempts ]; do
    : > "$installerLog"
    installerStatus=0
    {
      curl -fsSL --show-error https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh 2>>"$installerLog" \
        | sh -s -- -b /tmp >>"$installerLog" 2>&1
    } || installerStatus=$?
    if [ -x /tmp/trivy ]; then
      break
    fi
    if [ $attempt -lt $maxAttempts ]; then
      sleepSeconds=$((attempt * 5))
      echo "Trivy install attempt $attempt failed (exit=$installerStatus, binary not at /tmp/trivy); retrying in ${sleepSeconds}s..." >&2
      [ -s "$installerLog" ] && sed 's/^/  | /' "$installerLog" >&2
      sleep $sleepSeconds
    fi
    attempt=$((attempt + 1))
  done
  # Last-resort fallback: the retry loop above installs the `latest`
  # Trivy, whose tag lookup can transiently fail (a rate-limited or empty
  # GitHub response makes upstream `install.sh` log `unable to find ''`
  # and drop no binary). Before failing the whole stage, try once more
  # against an explicit, known-good version so a flaky `latest` lookup
  # alone cannot red the pipeline. Override the pin via TRIVY_PINNED_VERSION
  # (any tag from https://github.com/aquasecurity/trivy/releases, e.g. v0.72.0).
  if [ ! -x /tmp/trivy ]; then
    : "${TRIVY_PINNED_VERSION:=v0.72.0}"
    echo "Trivy 'latest' install failed after $maxAttempts attempts; falling back to pinned $TRIVY_PINNED_VERSION..." >&2
    : > "$installerLog"
    installerStatus=0
    {
      curl -fsSL --show-error https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh 2>>"$installerLog" \
        | sh -s -- -b /tmp "$TRIVY_PINNED_VERSION" >>"$installerLog" 2>&1
    } || installerStatus=$?
  fi
  if [ ! -x /tmp/trivy ]; then
    echo "ERROR: Trivy install failed after $maxAttempts 'latest' attempts and a pinned ${TRIVY_PINNED_VERSION:-v0.72.0} fallback (last exit=$installerStatus). Common causes include a GitHub API rate limit on the 'latest' tag lookup, transient network failures, raw.githubusercontent.com being blocked, or upstream GitHub downtime. Last installer/curl output:" >&2
    [ -s "$installerLog" ] && sed 's/^/  | /' "$installerLog" >&2
    echo "Re-run the pipeline or pin a Trivy version explicitly." >&2
    rm -f "$installerLog"
    exit 1
  fi
  rm -f "$installerLog"
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

# As with the SCA scan, Trivy's filesystem walk parses `pom.xml` for the
# package inventory and can abort with a FATAL error when Maven Central
# rate-limits the runner (HTTP 429), leaving no `trivy.json` for the SARIF
# conversion below. If the online scan produces no report because a remote
# repository was unreachable, retry once with `--offline-scan` (misconfig
# detection itself needs no remote dependency resolution).
trivyLog="/tmp/trivy-misconfig-run.log"
EXIT_CODE=0
trivy filesystem \
  --scanners misconfig \
  ${trivy_tf_exclude_flag:+$trivy_tf_exclude_flag} \
  --format json \
  --output "$jsonFile" \
  --exit-code 1 \
  "$(pwd)" > "$trivyLog" 2>&1 || EXIT_CODE=$?
cat "$trivyLog"

if [ ! -f "$jsonFile" ] && grep -qiE "remote Maven repository returned|Too Many Requests|429" "$trivyLog"; then
  echo "Trivy could not reach the remote Maven repository (rate-limited); retrying with --offline-scan..."
  EXIT_CODE=0
  trivy filesystem \
    --scanners misconfig \
    ${trivy_tf_exclude_flag:+$trivy_tf_exclude_flag} \
    --offline-scan \
    --format json \
    --output "$jsonFile" \
    --exit-code 1 \
    "$(pwd)" > "$trivyLog" 2>&1 || EXIT_CODE=$?
  cat "$trivyLog"
fi
rm -f "$trivyLog"

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
