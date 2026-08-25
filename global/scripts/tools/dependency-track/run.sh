#!/usr/bin/env sh
# Uploads the CycloneDX BOM at $PREFIX$REPORT_PATH/bom.json to Dependency-Track.
# Set DEBUG=1 to print curl validation logs (URL and form params).
#
# WORKS ON DEPENDENCY-TRACK 4.14.x AND 5.0.x WITH ONE CODE PATH. That is a
# verified finding, not an assumption, and it is recorded here so the next
# person does not add version detection this does not need. Read against the
# `5.0.5` tag of `DependencyTrack/dependency-track` (whose tree moved to
# `apiserver/src/main/java/...`, which is why the file looks absent at the 4.x
# path):
#
#   - `BomResource` is still `@Path("/v1/bom")`. v5 does add a `resources/v2`
#     package, but it holds no BOM resource -- uploads stay on v1.
#   - The multipart form parameters are IDENTICAL: `project`, `autoCreate`,
#     `projectName`, `projectVersion`, `projectTags`, `parentName`,
#     `parentVersion`, `parentUUID`, `isLatest`, `bom`.
#   - Authentication is still the `X-Api-Key` header
#     (`alpine.server.auth.ApiKeyAuthenticationService`).
#
# One model change DOES land in v5 and is called out because it bites anything
# that READS a project back: the `ACTIVE` column became `INACTIVE_SINCE`
# (a nullable timestamp, `READ_ONLY` in the schema), with `isActive()` kept as
# a derived accessor. Nothing here reads a project, so nothing here changes.

bomFile="$PREFIX$REPORT_PATH/bom.json"

# Skip the upload cleanly when no CycloneDX BOM was produced. This happens
# for consumers without a language-specific BOM generator. Without this
# guard `jq`/`curl` would error on the missing file and red the job.
if [ ! -f "$bomFile" ]; then
  echo "No CycloneDX BOM at $bomFile — skipping Dependency-Track upload."
  exit 0
fi

# `// empty` rather than a bare path, because `jq -r` prints the STRING `null`
# for a missing key. That string is a perfectly valid project name, so a BOM
# without `metadata.component` used to create a project literally called
# `null` and then keep updating it on every build -- a silent, portfolio-wide
# mess that no exit code ever reported.
projectName="${DEPENDENCY_TRACK_PROJECT_NAME:-$(jq -r '.metadata.component.name // empty' "$bomFile" | sed 's|/|-|g')}"
if [ -z "$projectName" ]; then
  echo "ERROR: $bomFile has no .metadata.component.name." >&2
  echo "       Dependency-Track identifies a project by (name, version), so an" >&2
  echo "       upload without a name cannot be attributed to anything. Fix the" >&2
  echo "       BOM generator, or set DEPENDENCY_TRACK_PROJECT_NAME explicitly." >&2
  exit 1
fi

# A missing version is NOT fatal. Dependency-Track trims an empty
# `projectVersion` to null and keeps a single versionless project, which is a
# stable identity that every build updates -- strictly better than the old
# behaviour of creating one project pinned to the literal version `null`.
projectVersion="${DEPENDENCY_TRACK_PROJECT_VERSION:-$(jq -r '.metadata.component.version // empty' "$bomFile")}"
if [ -z "$projectVersion" ]; then
  echo "WARNING: $bomFile has no .metadata.component.version — uploading as a versionless project." >&2
fi

# normalize base URL (strip trailing slash and trailing /api to avoid /api/api)
baseUrl="${DEPENDENCY_TRACK_HOST_URL%/}"
baseUrl="${baseUrl%/api}"
bomUploadUrl="$baseUrl/api/v1/bom"

# --- Which ref is this, and what may it do? --------------------------------
#
# Two separate questions, deliberately, because only one of them can be
# answered on every platform:
#
#   dt_is_release_ref     -- is this the default branch or a tag? Answerable on
#                            GitLab (which publishes CI_DEFAULT_BRANCH) and for
#                            tags everywhere. NOT answerable for a branch build
#                            on Azure DevOps or GitHub Actions unless the caller
#                            says what the default branch is.
#   dt_is_pull_request    -- is this a merge/pull request? Answerable on all
#                            three from an unambiguous ref shape.
#
# The asymmetry is not laziness. Azure DevOps publishes NO variable carrying the
# repository's default branch: `Build.Repository.*` is Name, Uri, Provider, ID,
# LocalPath, Clean, Tfvc.Workspace and Git.SubmoduleCheckout, and nothing else
# (checked against Microsoft's predefined-variables reference, not assumed --
# an earlier draft of this script used `Build.Repository.DefaultBranch`, which
# does not exist, so the comparison would have been against an empty string and
# every Azure upload would have silently stopped). GitHub Actions exposes the
# default branch only through the `github.event.repository` context, not the
# environment.
#
# DEPENDENCY_TRACK_DEFAULT_BRANCH supplies it where the platform cannot.

# Is this ref a merge/pull request? Positively identifiable everywhere.
dt_is_pull_request() {
  [ -n "${CI_MERGE_REQUEST_IID:-}" ] && return 0
  case "${BUILD_SOURCEBRANCH:-}" in refs/pull/*) return 0 ;; esac
  case "${GITHUB_REF:-}" in refs/pull/*) return 0 ;; esac
  [ "${BUILD_REASON:-}" = 'PullRequest' ] && return 0
  return 1
}

# Is this ref one whose BOM represents a release? Returns 1 when it is not, and
# also when it simply cannot be told -- the caller treats "unknown" as "not
# latest", which withholds a flag rather than moving one.
dt_is_release_ref() {
  dt_is_pull_request && return 1

  # Tags are unambiguous on all three platforms.
  [ -n "${CI_COMMIT_TAG:-}" ] && return 0
  case "${BUILD_SOURCEBRANCH:-}" in refs/tags/*) return 0 ;; esac
  case "${GITHUB_REF:-}" in refs/tags/*) return 0 ;; esac

  # GitLab publishes the default branch, so a branch build is decidable.
  if [ -n "${CI_COMMIT_BRANCH:-}" ] && [ -n "${CI_DEFAULT_BRANCH:-}" ]; then
    [ "$CI_COMMIT_BRANCH" = "$CI_DEFAULT_BRANCH" ] && return 0
    return 1
  fi

  # Elsewhere, only if the caller told us. Both the bare name (`main`) and the
  # full ref (`refs/heads/main`) are accepted so a consumer can paste whichever
  # their platform hands them.
  if [ -n "${DEPENDENCY_TRACK_DEFAULT_BRANCH:-}" ]; then
    _want="${DEPENDENCY_TRACK_DEFAULT_BRANCH#refs/heads/}"
    for _ref in "${BUILD_SOURCEBRANCH:-}" "${GITHUB_REF:-}" "${CI_COMMIT_BRANCH:-}"; do
      [ -n "$_ref" ] || continue
      [ "${_ref#refs/heads/}" = "$_want" ] && return 0
    done
    return 1
  fi

  return 1
}

# A merge/pull request must not create a project.
#
# `(name, version)` IS a project's identity, so an upload from a branch whose
# version file has already been bumped creates that version's project BEFORE
# the merge — and if the merge never happens, the project stays forever. This
# is the single largest contributor to portfolio sprawl and it is gated HERE,
# in the one shared script, rather than in each platform's YAML: a consumer
# pinned to an older template revision still gets the fix, and it is the only
# form of the rule that `make test-dependency-track` can exercise offline.
#
# Only a POSITIVELY identified pull request is skipped. A branch build that
# cannot be classified still uploads, because "I could not tell" must not
# silently mean "nothing was recorded".
if dt_is_pull_request && [ "${DEPENDENCY_TRACK_UPLOAD_ON_PULL_REQUEST:-false}" != 'true' ]; then
  echo "Merge/pull request build — skipping Dependency-Track upload."
  echo "  A pull request's BOM would create a permanent project for a version that may never merge."
  echo "  Set DEPENDENCY_TRACK_UPLOAD_ON_PULL_REQUEST=true to upload anyway."
  exit 0
fi

# Whether this upload claims the "latest version" flag.
#
# WHY THIS IS NOT UNCONDITIONALLY TRUE ANY MORE. `isLatest` is what a collection
# project with `AGGREGATE_LATEST_VERSION_CHILDREN` reads its metrics from, and at
# most one version per name can carry it. Asserting it from every pipeline run
# meant a build of an OLD version silently moved the flag backwards, and the
# parent then aggregated a stale child — reporting a risk score that was simply
# the wrong version's. Nothing errors when that happens.
if [ -n "${DEPENDENCY_TRACK_IS_LATEST:-}" ]; then
  isLatest="$DEPENDENCY_TRACK_IS_LATEST"
elif dt_is_release_ref; then
  isLatest='true'
else
  isLatest='false'
fi

# Capture the HTTP status and response body instead of `curl --fail`, which
# hides Dependency-Track's error message and leaves only a bare
# `curl: (22) ... 400` in the log. On failure the body is echoed so the
# actual rejection reason is visible in the pipeline output.
# TLS certificate verification is ON by default so the API key (sent in the
# `X-Api-Key` header) cannot be captured via a MITM. Set
# DEPENDENCY_TRACK_INSECURE=1 to skip verification for a DT endpoint with a
# self-signed / private-CA certificate (prefer trusting the CA on the agent).
# `set --` builds every flag as a quoted positional (no word-splitting), which
# is also what keeps a project name containing a space intact.
set --
if [ -n "${DEPENDENCY_TRACK_INSECURE:-}" ]; then
  set -- "$@" --insecure
fi

# Upload via the projectName + projectVersion + autoCreate path (an
# idempotent upsert). Dependency-Track's `/api/v1/bom` treats `project`
# (a project UUID) and `projectName`/`projectVersion` as MUTUALLY EXCLUSIVE
# — since 4.12 a request carrying both is rejected with HTTP 400. The
# previous implementation looked up the existing project's UUID and then
# POSTed it *together with* `projectVersion`, so every build after the
# project's first upload failed with 400 (the UUID lookup only misses on
# the very first run, which is why the job was "always breaking"). Sending
# only `projectName` + `projectVersion` with `autoCreate=true` creates the
# project on the first upload and updates it on every subsequent one.
set -- "$@" \
  -F "projectName=$projectName" \
  -F "projectVersion=$projectVersion" \
  -F 'autoCreate=true' \
  -F "isLatest=$isLatest"

# Optional collection parent.
#
# READ THIS BEFORE RELYING ON IT. `BomResource.uploadBom` resolves and attaches
# the parent ONLY inside its `if (project == null && autoCreate)` branch — the
# same in 4.14 and in 5.0.5, checked in both. For a project that ALREADY exists
# both `parentName` and `parentVersion` are read and then ignored: no error, no
# warning, no field in the response to notice. So these fields parent the
# projects this pipeline creates from here on, and can never re-parent one that
# is already in the portfolio. Adopting an existing portfolio needs
# `PATCH /api/v1/project/{uuid}` from an administrative job, not this script.
#
# The parent must exist before the first child upload; a missing one is
# answered with HTTP 404 `The parent project could not be found.` even with
# `autoCreate=true`.
if [ -n "${DEPENDENCY_TRACK_PARENT_NAME:-}" ]; then
  set -- "$@" -F "parentName=$DEPENDENCY_TRACK_PARENT_NAME"
  if [ -n "${DEPENDENCY_TRACK_PARENT_VERSION:-}" ]; then
    set -- "$@" -F "parentVersion=$DEPENDENCY_TRACK_PARENT_VERSION"
  fi
fi

set -- "$@" -F "bom=@$bomFile"

[ -n "${DEBUG:-}" ] && echo "[DEBUG] POST bom: url=$bomUploadUrl projectName=$projectName projectVersion=$projectVersion isLatest=$isLatest parentName=${DEPENDENCY_TRACK_PARENT_NAME:-<none>} bomFile=$bomFile" >&2

responseFile="${TMPDIR:-/tmp}/dependency-track-response.$$"

# The API key goes in through a curl config file on STDIN, never on argv.
#
# `-H "X-Api-Key: $DEPENDENCY_TRACK_TOKEN"` builds a byte-identical request, but
# argv is world-readable through `ps` and `/proc/<pid>/cmdline` for the lifetime
# of the process — which on a shared or self-hosted runner means any other job
# on that host. This is the same reasoning that keeps the token off argv in
# `global/scripts/deploy/render/run.sh` (`curl --config -`) and the NVD key off
# argv in the Dependency-Check runner (`-DnvdApiKeyEnvironmentVariable`).
#
# Backslashes and double quotes are escaped because curl parses a double-quoted
# config value with C-style escapes; an unescaped one would truncate the header.
escapedToken=$(printf '%s' "${DEPENDENCY_TRACK_TOKEN:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
httpStatus=$(printf 'header = "X-Api-Key: %s"\n' "$escapedToken" | curl --config - "$@" --silent --show-error \
  --output "$responseFile" --write-out '%{http_code}' \
  --request POST "$bomUploadUrl")

# `--write-out` always prints a status; `000` means curl never received an
# HTTP response (DNS/TLS/connection failure).
if [ "${httpStatus:-000}" -ge 200 ] && [ "${httpStatus:-000}" -lt 300 ]; then
  echo "Uploaded BOM to Dependency-Track (projectName=$projectName projectVersion=$projectVersion isLatest=$isLatest, HTTP $httpStatus)."
  rm -f "$responseFile"
else
  echo "ERROR: Dependency-Track rejected the BOM upload (HTTP $httpStatus). Response body:" >&2
  [ -s "$responseFile" ] && sed 's/^/  | /' "$responseFile" >&2
  rm -f "$responseFile"
  exit 1
fi
