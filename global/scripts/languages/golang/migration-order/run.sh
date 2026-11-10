#!/usr/bin/env sh
# Fails when a goose migration added on this branch is not newer than the newest migration the
# target branch already holds in the same directory.
#
# goose numbers every migration and, by default, refuses to run when it finds one older than the
# version the database has already reached ("found N missing migrations before current version").
# Two branches that each name a migration when they start, and merge in the opposite order, leave
# exactly that file behind. Review does not see it, and neither do the tests, which migrate an
# empty database: the first deploy after the second merge runs the migrations, and the service
# does not start until somebody renames the file. A pull request is the last point where that
# rename costs nothing.
#
# Which directories hold goose migrations is read from the files, not configured: a directory
# counts when one of its tracked `<version>_<name>.sql` files carries goose's `-- +goose Up`
# annotation, or one of its `<version>_<name>.go` files registers itself through
# `goose.AddMigration...`. Trees named `testdata` or `vendor` are skipped, as the go tool skips
# them. Each directory is compared with itself, because goose migrates one directory at a time.
#
# A version is the number before the first `_`, as goose reads it, so timestamped
# (`20260101120000_`) and sequential (`00042_`) numbering are both understood. Versions are
# compared as digit strings of any length, never through shell arithmetic, which reads a leading
# zero as octal.
#
# Usage: run.sh [target-branch]
#   The target branch defaults to the pull request's -- Azure DevOps, GitHub Actions and GitLab CI
#   each name it -- and otherwise to the default branch of `origin`. It is fetched from `origin`
#   first, so a target branch that moved after this branch was opened is the one judged against.
#
# Environment:
#   GOOSE_MIGRATION_DIRS  space-separated directories to check instead of the detected ones, or
#                         `none` to turn the check off (for a service that runs goose with missing
#                         migrations allowed, which applies an older file on purpose)
#
# Exit status: 0 when every new migration is newer, 1 when one is not, and 2 when the check could
# not run: no git repository, a target branch that cannot be fetched, or a configured directory
# that holds no migration.
set -eu

# A goose migration's file name: an all-digit version, `_`, a name, and `.sql` or `.go`. Brackets
# rather than backslashes, so the pattern means the same in every awk that reads it.
MIGRATION_NAME='^[0-9]+_.*[.](sql|go)$'
export MIGRATION_NAME

requested_target="${1:-}"

fail_setup() {
    printf 'migration-order: %s\n' "$1" >&2
    exit 2
}

# Reads repository paths on stdin and keeps those whose file name is a goose migration's.
migration_paths() {
    awk -F/ '
        $NF ~ ENVIRON["MIGRATION_NAME"] && $NF !~ /_test[.]go$/
    '
}

# Reads repository paths on stdin and prints the name of each one directly inside directory $1:
# goose reads one directory, not the tree under it.
in_dir() {
    MIGRATION_DIR="$1" awk '
        BEGIN {
            dir = ENVIRON["MIGRATION_DIR"]
            prefix = (dir == ".") ? "" : dir "/"
        }
        prefix == "" || index($0, prefix) == 1 {
            name = substr($0, length(prefix) + 1)
            if (name != "" && index(name, "/") == 0) print name
        }
    '
}

# Prints every directory that holds goose migrations, relative to the repository root.
detect_dirs() {
    {
        git -c core.quotePath=false grep -l -I -E '^--[[:space:]]*[+]goose[[:space:]]+[Uu][Pp]' -- '*.sql' || true
        git -c core.quotePath=false grep -l -I -E 'goose[.]Add[A-Za-z]*Migration' -- '*.go' || true
    } | migration_paths | awk -F/ '
        {
            dir = "."
            for (i = 1; i < NF; i++) {
                if ($i == "testdata" || $i == "vendor") next
                dir = (i == 1) ? $i : dir "/" $i
            }
            print dir
        }
    ' | sort -u
}

if ! top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    fail_setup 'not inside a git repository'
fi
cd "$top" || fail_setup "cannot enter '$top'"

# --- which directories -------------------------------------------------------------------------
if [ "${GOOSE_MIGRATION_DIRS:-}" = 'none' ]; then
    echo 'migration-order: turned off (GOOSE_MIGRATION_DIRS=none)'
    exit 0
fi

if [ -n "${GOOSE_MIGRATION_DIRS:-}" ]; then
    dirs=''
    set -f
    # shellcheck disable=SC2086 # a space-separated list by contract; globbing is off above
    set -- $GOOSE_MIGRATION_DIRS
    set +f
    for dir in "$@"; do
        dir="${dir#./}"
        dir="${dir%/}"
        [ -n "$dir" ] || dir='.'
        # A directory named by hand that holds nothing would make the check pass by not looking.
        if [ -z "$(git -c core.quotePath=false ls-files | migration_paths | in_dir "$dir")" ]; then
            fail_setup "GOOSE_MIGRATION_DIRS names '$dir', which holds no goose migration"
        fi
        dirs="$dirs$dir
"
    done
else
    dirs="$(detect_dirs)"
fi

if [ -z "$dirs" ]; then
    echo 'migration-order: no goose migrations in this repository, nothing to check'
    exit 0
fi

# --- which target --------------------------------------------------------------------------------
target="$requested_target"
if [ -z "$target" ]; then
    # Azure DevOps names the full ref (`refs/heads/main`) for an Azure Repos pull request and the
    # bare branch for a GitHub one; GitHub Actions and GitLab CI name the branch.
    for candidate in "${SYSTEM_PULLREQUEST_TARGETBRANCH:-}" "${GITHUB_BASE_REF:-}" "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}"; do
        if [ -n "$candidate" ]; then
            target="$candidate"
            break
        fi
    done
fi
if [ -z "$target" ]; then
    target="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    target="${target#origin/}"
fi
target="${target#refs/heads/}"
target="${target:-main}"
base_ref="refs/remotes/origin/$target"

# Only the target's tree is compared, never its history. A checkout is shallow by default on every
# platform, and a fetch without a depth would deepen it with the target's whole history.
depth=''
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || true)" = 'true' ]; then
    depth='--depth=1'
fi
if GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags ${depth:+"$depth"} origin "+refs/heads/$target:$base_ref"; then
    :
elif git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
    echo "migration-order: WARNING: could not fetch '$target' from origin; comparing with the copy fetched earlier"
else
    fail_setup "cannot fetch '$target' from origin, and there is no earlier copy to compare with"
fi

echo "migration-order: comparing new goose migrations with '$target' ($(git rev-parse --short "$base_ref"))"

# --- the comparison ------------------------------------------------------------------------------
base_files="$(git -c core.quotePath=false ls-tree -r --name-only "$base_ref" | migration_paths)"
# Renames off: a renamed migration must be judged by its NEW version, so it has to show up as an
# addition rather than be folded into a rename.
added_files="$(git -c core.quotePath=false diff --no-renames --name-only --diff-filter=A "$base_ref" -- '*.sql' '*.go' | migration_paths)"

status=0
while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    base_names="$(printf '%s\n' "$base_files" | in_dir "$dir")"
    added_names="$(printf '%s\n' "$added_files" | in_dir "$dir")"
    if [ -z "$added_names" ]; then
        echo "$dir: no new migrations"
        continue
    fi
    if [ -z "$base_names" ]; then
        echo "$dir: no migrations on '$target' yet, nothing to compare with"
        continue
    fi
    {
        printf '%s\n' "$base_names" | sed 's/^/B /'
        printf '%s\n' "$added_names" | sed 's/^/A /'
    } | MIGRATION_DIR="$dir" TARGET_BRANCH="$target" awk '
        # The version as goose reads it, without its leading zeros.
        function version(name,    v) {
            v = name
            sub(/_.*/, "", v)
            sub(/^0+/, "", v)
            return (v == "") ? "0" : v
        }
        # a > b for digit strings without leading zeros: the longer one is larger, and equal lengths
        # compare as text. Exact at any length, where an awk number (a double) is not past 2^53.
        function newer(a, b) {
            if (length(a) != length(b)) return length(a) > length(b)
            return a > b
        }
        {
            kind = substr($0, 1, 1)
            name = substr($0, 3)
        }
        kind == "B" {
            v = version(name)
            if (newest == "" || newer(v, newest)) { newest = v; newest_name = name }
            next
        }
        kind == "A" { added[++count] = name }
        END {
            printf "%s: newest on %s is %s\n", ENVIRON["MIGRATION_DIR"], ENVIRON["TARGET_BRANCH"], newest_name
            for (i = 1; i <= count; i++) {
                v = version(added[i])
                if (v in seen) {
                    printf "  FAIL  %s has the same version as %s, also new on this branch\n", added[i], seen[v]
                    failed = 1
                    continue
                }
                seen[v] = added[i]
                if (newer(v, newest)) {
                    printf "  ok    %s\n", added[i]
                } else {
                    printf "  FAIL  %s is not newer than %s\n", added[i], newest_name
                    failed = 1
                }
            }
            exit failed ? 1 : 0
        }
    ' || status=1
done <<EOF
$dirs
EOF

if [ "$status" -ne 0 ]; then
    echo ''
    echo '============================================================'
    echo '  ERROR: a new goose migration is not newer than the newest'
    echo "  migration already on '$target'."
    echo ''
    echo '  goose refuses to apply a migration older than the version'
    echo '  the database has reached ("missing migrations before'
    echo '  current version"), so the first deploy after this merge'
    echo '  would stop there.'
    echo ''
    echo '  Rename each file marked FAIL so its version is newer:'
    echo '  a fresh timestamp (date -u +%Y%m%d%H%M%S) or, with'
    echo '  sequential numbering, the next free number.'
    echo '============================================================'
    echo ''
fi
exit "$status"
