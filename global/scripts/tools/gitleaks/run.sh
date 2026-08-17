#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="gitleaks" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$REPORT_PATH/gitleaks.json"

# Path to the GitLab-customized rule set shipped in this repo. The second
# detection pass selects it via `--config`; the project's own `.gitleaks.toml`
# and `.gitleaksignore` are auto-discovered from the source root for both
# passes, so the project's working tree is never touched.
GITLAB_CONFIG_PATH="$SCRIPTS_DIR/global/scripts/tools/gitleaks/.gitleaks.toml"

# Install Gitleaks if not already available. Gitleaks publishes a static Go
# binary on every GitHub release, so it is downloaded directly instead of
# being pulled as a Docker image -- Docker Hub now enforces an anonymous pull
# rate limit, which made every uncached CI run risk a `toomanyrequests`
# failure. This mirrors the shellcheck/hadolint installation pattern.
#
# The version is PINNED and the download is CHECKSUM-VERIFIED. This script
# previously resolved `releases/latest` at run time and executed whatever came
# back, unverified: the version that scanned a given commit was therefore
# whatever upstream had published that morning, a re-run could reach a
# different verdict on identical code, and anyone able to answer the request --
# upstream, their CDN, or a proxy on the runner's egress path -- chose the
# bytes that then ran with the job's token in scope. `GITLEAKS_VERSION`
# overrides the pin for an operator responding to an upstream CVE ahead of a
# release here; the matching digest must be supplied with it.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

# Replace an installed Gitleaks whose version differs from the pin, in either
# direction. The old check only ever upgraded towards `latest`, so a persistent
# agent that had drifted ahead of the pin kept its own version and quietly
# scanned with rules this repository never chose.
gitleaks_matches_pin() {
  _gl_current=$(gitleaks version 2>/dev/null | sed 's/^v//')
  [ "$_gl_current" = "${GITLEAKS_VERSION#v}" ]
}

if ! command -v gitleaks > /dev/null 2>&1 || ! gitleaks_matches_pin; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        GITLEAKS_ARCH="x64";   GITLEAKS_DIGEST_ARCH="X64" ;;
    aarch64|arm64) GITLEAKS_ARCH="arm64"; GITLEAKS_DIGEST_ARCH="ARM64" ;;
    armv7l)        GITLEAKS_ARCH="armv7"; GITLEAKS_DIGEST_ARCH="ARMV7" ;;
    *)
      echo "Unsupported architecture: $ARCH" >&2
      exit 1
      ;;
  esac

  GITLEAKS_SHA256=$(pinned_digest GITLEAKS "$GITLEAKS_DIGEST_ARCH") || exit 1

  echo "Installing Gitleaks $GITLEAKS_VERSION (linux/$GITLEAKS_ARCH)..."
  if ! download_verified \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION#v}/gitleaks_${GITLEAKS_VERSION#v}_linux_${GITLEAKS_ARCH}.tar.gz" \
    /tmp/gitleaks.tar.gz \
    "$GITLEAKS_SHA256"; then
    exit 1
  fi
  # Guard extraction and permission-setting explicitly. Without `set -e` a
  # failed `tar` (corrupt archive, no space in /tmp) or `chmod` would otherwise
  # fall through to the `command -v` check below and surface only as the opaque
  # "installation did not produce a runnable binary" error, hiding the real
  # cause -- and the downloaded tarball would be left behind.
  if ! tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks; then
    echo "ERROR: failed to extract Gitleaks $GITLEAKS_VERSION from /tmp/gitleaks.tar.gz (corrupt download or no space in /tmp)." >&2
    rm -f /tmp/gitleaks.tar.gz
    exit 1
  fi
  rm -f /tmp/gitleaks.tar.gz
  if ! chmod +x /tmp/gitleaks; then
    echo "ERROR: failed to make the Gitleaks binary at /tmp/gitleaks executable." >&2
    rm -f /tmp/gitleaks
    exit 1
  fi
  # Move the downloaded binary into the user's ~/.local/bin (on PATH via the
  # shared preamble) so nothing is installed to a root-owned location.
  mv /tmp/gitleaks "$HOME/.local/bin/gitleaks"
fi

# Fail loudly if the binary is still not runnable rather than falling through
# to an opaque `gitleaks: not found` at the first `gitleaks detect` call below.
if ! command -v gitleaks > /dev/null 2>&1; then
  echo "ERROR: Gitleaks installation did not produce a runnable 'gitleaks' binary." >&2
  exit 1
fi

# Gitleaks scans the project's full Git history. In CI the working tree is
# often owned by a different user than the one running the scan, so Git
# refuses to operate until the directory is explicitly marked as trusted.
git config --global --add safe.directory "$(pwd)" > /dev/null 2>&1 || true

# Determine the scan scope.
#
# Default `gitleaks detect` (no `--log-opts`) runs
# `git log -p -U0 --full-history --all --diff-filter=tuxdb` — the `--all`
# walks every ref present in the local clone (every branch, every tag),
# not just commits reachable from HEAD. In CI, the checkout step typically
# fetches the full remote (e.g. Azure DevOps `fetchDepth: 0` + `fetchTags:
# true`, GitLab CI's default full clone), so unmerged feature branches
# carrying their own secrets end up in the local `.git/` and are walked
# on every build — including builds for unrelated branches and `main`.
# The result: a secret committed to `feat/leaky-thing` fails the `main`
# pipeline, the `release/x.y` pipeline, and every other branch build,
# instead of failing only on the branch that owns it.
#
# Scope the scan to commits this build is actually responsible for:
#   - Pull / merge request build: commits unique to the PR
#     (`origin/<target>..HEAD`). The base branch history was already
#     scanned by its own pipeline runs and triaging the same findings
#     on every downstream PR is wasted work.
#   - Branch / tag build: commits reachable from HEAD only (`HEAD`).
#     The branch / tag's actual ancestry, ignoring whatever other refs
#     happen to be fetched into the local clone.
TARGET_BRANCH=""
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
  TARGET_BRANCH="$GITHUB_BASE_REF"
elif [ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]; then
  TARGET_BRANCH="$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
elif [ -n "${SYSTEM_PULLREQUEST_TARGETBRANCH:-}" ]; then
  TARGET_BRANCH="${SYSTEM_PULLREQUEST_TARGETBRANCH#refs/heads/}"
fi

LOG_OPTS=""
if [ -n "$TARGET_BRANCH" ]; then
  # Some CI checkouts are shallow or only fetch the PR ref, so the target
  # branch may not exist as `origin/<target>` locally. Try to fetch it; if it
  # still cannot be resolved, fall back to a HEAD-only scan with a warning
  # instead of silently scanning nothing or walking every ref.
  if ! git rev-parse --verify --quiet "origin/$TARGET_BRANCH" > /dev/null 2>&1; then
    git fetch --no-tags --quiet origin "+refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" 2>/dev/null || true
  fi
  if git rev-parse --verify --quiet "origin/$TARGET_BRANCH" > /dev/null 2>&1; then
    LOG_OPTS="origin/$TARGET_BRANCH..HEAD"
    echo "Pull / merge request context detected; scoping Gitleaks to: $LOG_OPTS"
  else
    LOG_OPTS="HEAD"
    echo "WARN: pull / merge request context detected (target=$TARGET_BRANCH) but the target ref is unreachable; falling back to HEAD-only scan ($LOG_OPTS)." >&2
  fi
else
  LOG_OPTS="HEAD"
  echo "Branch / tag build detected; scoping Gitleaks to: $LOG_OPTS"
fi

# Pass 1: gitleaks defaults + the project's `.gitleaks.toml` / `.gitleaksignore`
# if present (gitleaks auto-discovers them at the source root).
if [ -n "$LOG_OPTS" ]; then
  gitleaks detect --source "$(pwd)" --report-path "$REPORT_PATH/gitleaks-01.json" --log-opts "$LOG_OPTS" || EXIT_CODE=$?
else
  gitleaks detect --source "$(pwd)" --report-path "$REPORT_PATH/gitleaks-01.json" || EXIT_CODE=$?
fi

# Pass 2: GitLab-customized rule set, selected explicitly with `--config`. The
# project's `.gitleaksignore` (fingerprint allowlist) is still auto-discovered
# from the source root and applies to this pass too. Skipped when pass 1
# already failed so the first finding is the one reported.
if [ -z "$EXIT_CODE" ]; then
  if [ -n "$LOG_OPTS" ]; then
    gitleaks detect --source "$(pwd)" --report-path "$REPORT_PATH/gitleaks-02.json" --config "$GITLAB_CONFIG_PATH" --log-opts "$LOG_OPTS" || EXIT_CODE=$?
  else
    gitleaks detect --source "$(pwd)" --report-path "$REPORT_PATH/gitleaks-02.json" --config "$GITLAB_CONFIG_PATH" || EXIT_CODE=$?
  fi
fi

if ls "$REPORT_PATH"/gitleaks-*.json 1> /dev/null 2>&1; then
  jq -s "add" "$REPORT_PATH"/gitleaks-*.json > "$fileName"
else
  echo "OK" > "$fileName"
fi

exit "${EXIT_CODE:-0}"
