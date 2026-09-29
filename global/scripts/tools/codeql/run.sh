#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="codeql" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

CODEQL_LANGUAGE="${1:?Usage: run.sh <language> (e.g., go, python, java, javascript, csharp)}"
fileName="$(pwd)/$REPORT_PATH/codeql.sarif"

CODEQL_RAM="${CODEQL_RAM:-}"

# Whether this is a CI runner: GitHub Actions and GitLab CI export CI on every job, Azure DevOps
# exports TF_BUILD. Anything else is a developer's machine running `make codeql`.
codeql_on_ci() {
  [ -n "${CI:-}" ] || [ -n "${TF_BUILD:-}" ]
}

# One thread on a CI runner, where CodeQL may share its host with other jobs -- see the RAM note
# below and `codeql_runs_on`. Every core on a developer's machine, where the scan is the one thing
# running: a single thread there turned a six-minute scan into hours. An explicit CODEQL_THREADS
# always wins.
if [ -z "${CODEQL_THREADS:-}" ]; then
  if codeql_on_ci; then
    CODEQL_THREADS=1
  else
    CODEQL_THREADS=0
  fi
fi

# What the database is built from. On a CI runner it is the checkout itself: a fresh clone holds
# nothing else. A developer's working tree also holds everything .gitignore keeps out of the
# repository -- an agent's worktrees under .claude/worktrees, vendored builds, old databases --
# and the extractor takes all of it: the Go autobuilder builds every go.mod under the source root,
# so thirty stale worktrees turned one module into 31, a 93 GB database and a scan still importing
# after 77 minutes. So a local scan copies the files git would ship -- the tracked ones still on
# disk, plus untracked ones no ignore rule excludes -- into a scratch directory and builds from
# there. Every path stays relative to the project root, so the report's locations and the
# `.codeql-false-positives` fingerprints (hashes of source lines, not of where they sit) come out
# as a CI run reports them. An untracked nested repository is left out, as `git add` would: git
# lists it as `dir/`, and taking its contents is how the stale worktrees would come back.
#
# CODEQL_SOURCE_SCOPE overrides the choice: `git` for that copy, `tree` for the directory as it is
# -- the way back for a build that needs a file .gitignore keeps out. Outside a git work tree the
# directory is scanned as it is, as it always was.
CODEQL_SOURCE_SCOPE="${CODEQL_SOURCE_SCOPE:-}"
if [ -z "$CODEQL_SOURCE_SCOPE" ]; then
  if codeql_on_ci; then
    CODEQL_SOURCE_SCOPE=tree
  else
    CODEQL_SOURCE_SCOPE=git
  fi
fi
case "$CODEQL_SOURCE_SCOPE" in
  git | tree) ;;
  *)
    echo "ERROR: CODEQL_SOURCE_SCOPE must be 'git' or 'tree', not '$CODEQL_SOURCE_SCOPE'." >&2
    exit 1
    ;;
esac

# When `--ram` is not given, CodeQL sizes its own JVM heap -- and inside a
# memory-limited container it gets that badly wrong, because the number it
# reasons from is the host's total rather than the cgroup's. On an 8 GiB CI pod
# it settled on a 1100 MB heap and left the query evaluator 660 MiB, which is
# not enough to evaluate the `security-and-quality` suite over a large codebase:
# the run died with `OutOfMemoryError "Java heap space"` on the FIRST query and
# wrote no SARIF at all.
#
# That failure mode is quiet in the worst way. The calling step is conventionally
# `continueOnError`, so the job went yellow rather than red, the report directory
# published as an empty artifact, and the SARIF-missing guard below never got to
# speak because `database analyze` had already exited non-zero. A repository can
# sit in that state indefinitely looking scanned while CodeQL has not evaluated a
# single query.
#
# So derive the budget from the container's real ceiling instead of leaving it to
# a guess. 75% leaves headroom for the extractor, the JVM's own non-heap overhead
# and the agent process itself. An explicit CODEQL_RAM always wins.
if [ -z "$CODEQL_RAM" ]; then
  . "$SCRIPTS_DIR/global/scripts/shared/memory.sh"
  detectedRamMb="$(detect_memory_limit_mb)" || detectedRamMb=''
  if [ -n "$detectedRamMb" ]; then
    candidateRamMb=$((detectedRamMb * 75 / 100))
    # Under this, an explicit budget would only be tighter than what CodeQL
    # would have picked on its own, so leave the decision with CodeQL and let it
    # report its own out-of-memory error rather than one we caused.
    if [ "$candidateRamMb" -ge 2048 ]; then
      CODEQL_RAM="$candidateRamMb"
      echo "Detected a ${detectedRamMb} MB memory ceiling for this runner."
    else
      echo "Detected a ${detectedRamMb} MB memory ceiling -- too small to improve on CodeQL's own default; leaving --ram unset."
    fi
  else
    echo "Could not detect a memory ceiling for this runner; leaving --ram unset."
  fi
fi

RAM_FLAG=""
if [ -n "$CODEQL_RAM" ]; then
  RAM_FLAG="--ram=$CODEQL_RAM"
  echo "CodeQL RAM limit set to ${CODEQL_RAM} MB"
fi
THREADS_FLAG="--threads=$CODEQL_THREADS"
echo "CodeQL threads set to $CODEQL_THREADS"

CONFIG_FLAG=""
if [ -f "$(pwd)/codeql-config.yml" ]; then
  CONFIG_FLAG="--codescanning-config=$(pwd)/codeql-config.yml"
  echo "Using project CodeQL config: codeql-config.yml"
fi

# Load project-level configuration if available (e.g. for Go build environment)
if [ "$CODEQL_LANGUAGE" = "go" ]; then
  INIT_SCRIPT="config.sh"
  if [ -f "$INIT_SCRIPT" ]; then
    # shellcheck disable=SC1090
    . ./"$INIT_SCRIPT"
  else
    echo "The '$INIT_SCRIPT' file was not found, skipping..."
  fi
fi

# Install CodeQL CLI if not already available.
#
# GitHub only publishes Linux x86_64 CodeQL bundles (`codeql-bundle-linux64.tar.gz`).
# There is no native Linux ARM64 build of CodeQL — see
# https://github.com/github/codeql-action/issues/2839. Running the x86_64
# bundle directly on aarch64 fails with `Exec format error` on the bundled
# JRE (`tools/linux64/java/bin/java`) and a chain of confusing downstream
# errors (missing SARIF file, `jq` "No such file" warnings, `[: Illegal
# number`). Fail fast with an actionable message instead so the operator
# knows to switch the runner.
# Unlike the other tool scripts, CodeQL is intentionally NOT self-updated when
# already present: the CLI ships as a ~1 GB bundle with no lightweight version
# handle, so re-downloading it on every run of a persistent agent would cost far
# more than the staleness it avoids. Refresh it out-of-band instead.
if ! command -v codeql > /dev/null 2>&1; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)
      ;;
    aarch64|arm64)
      echo "ERROR: CodeQL has no native Linux ARM64 build — only x86_64 is published upstream." >&2
      echo "Detected architecture: $ARCH" >&2
      echo "Run this stage on an x86_64 runner, or set up qemu-user-static binfmt emulation before invoking the SAST stage." >&2
      exit 1
      ;;
    *)
      echo "ERROR: Unsupported architecture for CodeQL: $ARCH (only x86_64 is supported)." >&2
      exit 1
      ;;
  esac

  # The bundle is PINNED and CHECKSUM-VERIFIED. `releases/latest/download/...`
  # was a double moving target: a new ~1 GB bundle lands every few weeks, so the
  # query pack that decided whether a commit was vulnerable changed underneath
  # the pipeline, and nothing recorded which one had run -- a SARIF report could
  # not be reproduced or even attributed to a CodeQL version after the fact.
  . "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
  . "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

  CODEQL_SHA256=$(pinned_digest CODEQL_BUNDLE LINUX64) || exit 1

  echo "Installing CodeQL CLI bundle $CODEQL_BUNDLE_VERSION..."
  if ! download_verified \
    "https://github.com/github/codeql-action/releases/download/${CODEQL_BUNDLE_VERSION}/codeql-bundle-linux64.tar.gz" \
    /tmp/codeql-bundle.tar.gz \
    "$CODEQL_SHA256"; then
    exit 1
  fi
  mkdir -p "$HOME/.local/share"
  tar -xzf /tmp/codeql-bundle.tar.gz -C "$HOME/.local/share"
  # Symlink the CodeQL launcher into the user's ~/.local/bin (on PATH via the
  # shared preamble); the bundle itself lives under ~/.local/share — no root.
  ln -sf "$HOME/.local/share/codeql/codeql" "$HOME/.local/bin/codeql"
  rm /tmp/codeql-bundle.tar.gz
fi

SOURCE_ROOT="$(pwd)"
SCAN_WORK=""
if [ "$CODEQL_SOURCE_SCOPE" = "git" ] && git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  SCAN_WORK="$(mktemp -d)" || exit 1
  trap 'rm -rf "$SCAN_WORK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir "$SCAN_WORK/source"
  if ! git ls-files -z --cached --others --exclude-standard > "$SCAN_WORK/listed"; then
    echo "ERROR: could not list the files git would ship; set CODEQL_SOURCE_SCOPE=tree to scan the directory as it is." >&2
    exit 1
  fi
  # shellcheck disable=SC2016 # the script is for the inner sh, which expands "$@" itself
  if ! xargs -0 sh -c 'for f do case $f in */) ;; *) if [ -e "$f" ] || [ -L "$f" ]; then printf "%s\0" "$f"; fi ;; esac; done' sh \
    < "$SCAN_WORK/listed" > "$SCAN_WORK/shipped" \
    || ! tar -c -f "$SCAN_WORK/source.tar" --null -T "$SCAN_WORK/shipped" \
    || ! tar -x -f "$SCAN_WORK/source.tar" -C "$SCAN_WORK/source"; then
    echo "ERROR: could not copy the files git would ship; set CODEQL_SOURCE_SCOPE=tree to scan the directory as it is." >&2
    exit 1
  fi
  rm -f "$SCAN_WORK/source.tar"
  SOURCE_ROOT="$SCAN_WORK/source"
  echo "Scanning the $(tr -cd '\0' < "$SCAN_WORK/shipped" | wc -c | tr -d ' ') file(s) git would ship, copied to $SOURCE_ROOT (CODEQL_SOURCE_SCOPE=git)."
else
  echo "Scanning $SOURCE_ROOT as it is (CODEQL_SOURCE_SCOPE=$CODEQL_SOURCE_SCOPE)."
fi

echo "Creating CodeQL database for language: $CODEQL_LANGUAGE"
# shellcheck disable=SC2086
if ! codeql database create \
  --language="$CODEQL_LANGUAGE" \
  --source-root="$SOURCE_ROOT" \
  $THREADS_FLAG \
  $CONFIG_FLAG \
  "$(pwd)/.codeql-db"; then
  echo "ERROR: 'codeql database create' failed for language '$CODEQL_LANGUAGE'." >&2
  if [ -n "$SCAN_WORK" ]; then
    echo "The build ran on the files git would ship; if it needs one .gitignore keeps out, set CODEQL_SOURCE_SCOPE=tree." >&2
  fi
  rm -rf "$(pwd)/.codeql-db"
  exit 1
fi

echo "Running CodeQL analysis..."
# shellcheck disable=SC2086
if ! codeql database analyze \
  --format=sarifv2.1.0 \
  --output="$fileName" \
  $RAM_FLAG \
  $THREADS_FLAG \
  "$(pwd)/.codeql-db" \
  "$CODEQL_LANGUAGE-security-and-quality.qls"; then
  echo "ERROR: 'codeql database analyze' failed for language '$CODEQL_LANGUAGE'." >&2
  rm -rf "$(pwd)/.codeql-db"
  exit 1
fi

echo "CodeQL analysis complete. Results written to: $fileName"

# Clean up database
rm -rf "$(pwd)/.codeql-db"

# Refuse to proceed if the SARIF was not produced — without this guard the
# downstream `jq`/arithmetic pipeline emitted confusing cascading errors
# ("Could not open file", "[: Illegal number") that masked the real cause.
if [ ! -f "$fileName" ]; then
  echo "ERROR: CodeQL completed but SARIF report was not produced at $fileName." >&2
  exit 1
fi

# Use default false positives file if the project doesn't provide one
fpFileExists=true
if [ ! -f ".codeql-false-positives" ]; then
  fpFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/codeql/.codeql-false-positives"
  cp "$defaultFile" .
fi

# Load false positive fingerprints
FP_FILE="$(pwd)/.codeql-false-positives"
FP_FILTER=$(grep -v '^\s*#' "$FP_FILE" | grep -v '^\s*$' | jq -R -s 'split("\n") | map(select(length > 0))')
FP_COUNT=$(echo "$FP_FILTER" | jq 'length')
if [ "$FP_COUNT" -gt 0 ]; then
  echo "Loaded $FP_COUNT false positive fingerprint(s) from .codeql-false-positives"
fi

# Count results excluding false positives matched by SARIF partialFingerprints
TOTAL_COUNT=$(jq '[.runs[].results[]] | length' "$fileName")
RESULT_COUNT=$(jq --argjson fp "$FP_FILTER" \
  '[.runs[].results[] | select(
    (.partialFingerprints // {} | to_entries | map(.value) | any(. as $h | $fp | any(. == $h))) | not
  )] | length' "$fileName")
SUPPRESSED=$((TOTAL_COUNT - RESULT_COUNT))

echo "CodeQL found $TOTAL_COUNT issue(s) total, $SUPPRESSED suppressed as false positive(s), $RESULT_COUNT remaining."
if [ "$RESULT_COUNT" -gt 0 ]; then
  jq -r --argjson fp "$FP_FILTER" \
    '.runs[].results[] | select(
      (.partialFingerprints // {} | to_entries | map(.value) | any(. as $h | $fp | any(. == $h))) | not
    ) | "  - \(.ruleId): \(.message.text) (\(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine))"' "$fileName"
  EXIT_CODE=1
fi

if [ "$fpFileExists" = false ]; then
  rm -f .codeql-false-positives
fi

exit ${EXIT_CODE:-0}
