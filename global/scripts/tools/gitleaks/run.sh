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
  GITLEAKS_VERSION=$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

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

  curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION#v}_linux_${GITLEAKS_ARCH}.tar.gz" -o /tmp/gitleaks.tar.gz
  tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks
  chmod +x /tmp/gitleaks
  rm -f /tmp/gitleaks.tar.gz
  export PATH="/tmp:$PATH"
fi

# Gitleaks scans the project's full Git history. In CI the working tree is
# often owned by a different user than the one running the scan, so Git
# refuses to operate until the directory is explicitly marked as trusted.
git config --global --add safe.directory "$(pwd)" > /dev/null 2>&1 || true

# Determine the scan scope.
#
# In a pull / merge request build the CI checks out the PR merge commit
# (HEAD = base + PR), and `gitleaks detect` defaults to `git log -p HEAD`
# — which walks every commit reachable from HEAD, i.e. the entire base
# branch history plus the PR commits. That base history was already
# scanned by the base branch's own pipeline runs, so re-scanning it on
# every PR is wasted work and inflates findings with hits the team has
# already triaged on `main`. Restrict the scope to commits unique to the
# PR (`origin/<target>..HEAD`). On branch / tag builds (including `main`),
# leave the scope at the default so the branch's own commits are scanned
# end-to-end.
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
  # still cannot be resolved, fall back to a full-history scan with a warning
  # instead of silently scanning nothing.
  if ! git rev-parse --verify --quiet "origin/$TARGET_BRANCH" > /dev/null 2>&1; then
    git fetch --no-tags --quiet origin "+refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" 2>/dev/null || true
  fi
  if git rev-parse --verify --quiet "origin/$TARGET_BRANCH" > /dev/null 2>&1; then
    LOG_OPTS="origin/$TARGET_BRANCH..HEAD"
    echo "Pull / merge request context detected; scoping Gitleaks to: $LOG_OPTS"
  else
    echo "WARN: pull / merge request context detected (target=$TARGET_BRANCH) but the target ref is unreachable; falling back to full-history scan." >&2
  fi
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
