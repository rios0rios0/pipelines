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
if ! command -v gitleaks > /dev/null 2>&1; then
  echo "Downloading Gitleaks..."

  # Resolve the latest version robustly. An unauthenticated `api.github.com`
  # call is rate limited to 60 requests/hour per IP, and on shared
  # GitHub-hosted runner IPs it intermittently returns HTTP 403 -- which left
  # GITLEAKS_VERSION empty. Because this script runs under POSIX `sh` (no
  # `set -e`), that empty value used to sail through a malformed download URL
  # and a failed extraction, surfacing only as a cryptic `gitleaks: not found`
  # at the first `gitleaks detect` below. Prefer the authenticated API when a
  # token is present (5000 requests/hour), then fall back to the github.com
  # `releases/latest` redirect, which is not API-rate-limited and needs no
  # token (works the same on GitHub Actions, GitLab CI, and Azure DevOps).
  GITHUB_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  GITLEAKS_VERSION=""
  if [ -n "$GITHUB_API_TOKEN" ]; then
    GITLEAKS_VERSION=$(curl -fsSL -H "Authorization: Bearer $GITHUB_API_TOKEN" https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  fi
  if [ -z "$GITLEAKS_VERSION" ]; then
    GITLEAKS_VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/gitleaks/gitleaks/releases/latest | sed 's#.*/tag/##')
  fi
  if [ -z "$GITLEAKS_VERSION" ]; then
    echo "ERROR: could not resolve the latest Gitleaks version (GitHub rate limit, outage, or network failure)." >&2
    exit 1
  fi

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        GITLEAKS_ARCH="x64" ;;
    aarch64|arm64) GITLEAKS_ARCH="arm64" ;;
    armv7l)        GITLEAKS_ARCH="armv7" ;;
    *)
      echo "Unsupported architecture: $ARCH" >&2
      exit 1
      ;;
  esac

  if ! curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION#v}_linux_${GITLEAKS_ARCH}.tar.gz" -o /tmp/gitleaks.tar.gz; then
    echo "ERROR: failed to download Gitleaks $GITLEAKS_VERSION (linux/$GITLEAKS_ARCH)." >&2
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
  export PATH="/tmp:$PATH"
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
