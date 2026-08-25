#!/usr/bin/env sh
set -e

# Prettier gate for the `10-code-check` stage.
#
# This is the JavaScript half of what `languages/dart/format/run.sh` does for
# Dart, and it existed nowhere until now. `style:eslint` runs the project's
# `lint:ci`, and a JavaScript project that follows the usual advice ALSO installs
# `eslint-config-prettier`, whose entire job is to switch off every ESLint rule
# that overlaps with Prettier. So the two halves cancelled out: ESLint was
# deliberately silent about formatting and Prettier never ran, which is not a
# formatting gate with a gap in it -- it is no formatting gate at all. The
# repository that prompted this had 348 unformatted files, a committed
# `.prettierrc`, a curated `.prettierignore`, and a green pipeline.
#
# Two modes, the same two the Dart runner has:
#   check (default) -- `--check`, the CI gate
#   --fix           -- `--write`, for `make lint`
#
# THE PROJECT'S OWN PRETTIER, never a floating one. `npx --yes prettier` would
# resolve the newest published release on every run, and unlike a linter -- where
# a new release adds findings -- a formatter's OUTPUT is the verdict: one major
# bump reformats the whole tree, so an untouched repository goes red on a day
# nobody changed anything. `knip` is pinned here for the same reason from the
# other direction. The version a project is held to is the one in its lockfile.
#
# SKIPPED, not failed, when the project does not use Prettier. Plenty of
# consumers do not, and a shared gate that fails them for a tool they never
# adopted is a gate that gets deleted. The rule is the honest one: if this
# project uses Prettier, its tree must be formatted. Same shape as Hadolint
# skipping a repository with no Dockerfile.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="prettier" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

MODE="check"
TARGETS=""
for arg in "$@"; do
  case "$arg" in
    --fix) MODE="fix" ;;
    *) TARGETS="$TARGETS $arg" ;;
  esac
done

# `.` covers the whole repository in one pass, which is what a repository-wide
# gate should do. What NOT to touch is `.prettierignore`'s job, and it is the
# consumer's file: generated clients, vendored copies and knowledge bases belong
# there, not in a target list this script would have to guess at.
if [ -z "$TARGETS" ]; then
  TARGETS="."
fi

# One `node` call rather than four greps. Reading `package.json` is the only
# thing here that needs a JSON parser, and asking it four separate times is four
# more places for a missing or malformed file to be handled differently.
#
# `|| true` because a malformed `package.json` must not take this job down: it
# fails the install step long before this one, with a message that names it.
PKG_FACTS=""
if [ -f package.json ]; then
  PKG_FACTS="$(node -e '
    const pkg = require(process.cwd() + "/package.json");
    const scripts = pkg.scripts || {};
    const deps = Object.assign({}, pkg.dependencies, pkg.devDependencies);
    const facts = [];
    if (pkg.prettier) facts.push("config");
    if (deps.prettier) facts.push("dependency");
    if (scripts["format:check"]) facts.push("script-check");
    if (scripts.format) facts.push("script-fix");
    console.log(facts.join(" "));
  ' 2>/dev/null || true)"
fi

js_has_fact() {
  case " $PKG_FACTS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Every name Prettier itself resolves a configuration from, minus the
# `package.json` key handled above. Kept as a list rather than a glob because
# `.prettierrc*` would also match `.prettierrc.backup` and `.prettierignore`.
js_has_config_file() {
  for candidate in \
    .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.json5 \
    .prettierrc.js .prettierrc.cjs .prettierrc.mjs .prettierrc.ts .prettierrc.toml \
    prettier.config.js prettier.config.cjs prettier.config.mjs prettier.config.ts; do
    if [ -f "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

# A DEPENDENCY alone counts, and so does a configuration file alone. Either one
# is a project saying it formats with Prettier; requiring both would let the gate
# be switched off by deleting a file, which is the opposite of a gate.
if ! js_has_config_file && ! js_has_fact config && ! js_has_fact dependency; then
  echo "No Prettier configuration and no prettier dependency found; skipping the formatting check."
  exit 0
fi

PACKAGE_MANAGER="npm"
if [ -f yarn.lock ]; then
  PACKAGE_MANAGER="yarn"
fi
if [ -n "$JS_PACKAGE_MANAGER" ]; then
  PACKAGE_MANAGER="$JS_PACKAGE_MANAGER"
fi

# Prefer the project's OWN script, the way `style:eslint` prefers `lint:ci`.
# A repository that narrows Prettier to a glob, or passes a flag, has said so
# there -- and second-guessing it from a shared library is how a gate starts
# reporting on files its owner deliberately excluded.
run_project_script() {
  echo "Running \"$PACKAGE_MANAGER run $1\"..."
  if [ "$PACKAGE_MANAGER" = 'yarn' ]; then
    yarn "$1"
  else
    npm run "$1"
  fi
}

# No project script, so call Prettier directly.
#
# Three resolutions, in the order they are cheapest and most certain:
# the linked binary, then the package manager's own runner for a Yarn Plug'n'Play
# tree (where `node_modules/` does not exist at all and the binary cannot be
# found by path), then `npx --no-install`. `--no-install` matters: a bare `npx
# prettier` DOWNLOADS one when the project has none, which is the floating
# resolve this script exists to avoid.
run_prettier_directly() {
  flag="$1"
  echo "Running \"prettier $flag $TARGETS\"..."
  # shellcheck disable=SC2086  # TARGETS is a deliberately word-split path list
  if [ -x node_modules/.bin/prettier ]; then
    node_modules/.bin/prettier "$flag" $TARGETS
  elif [ "$PACKAGE_MANAGER" = 'yarn' ]; then
    yarn prettier "$flag" $TARGETS
  else
    npx --no-install prettier "$flag" $TARGETS
  fi
}

if [ "$MODE" = "fix" ]; then
  if js_has_fact script-fix; then
    run_project_script format
  else
    run_prettier_directly --write
  fi
  exit 0
fi

EXIT_CODE=0
if js_has_fact script-check; then
  run_project_script format:check > "$REPORT_PATH/prettier.txt" 2>&1 || EXIT_CODE=$?
else
  run_prettier_directly --check > "$REPORT_PATH/prettier.txt" 2>&1 || EXIT_CODE=$?
fi

cat "$REPORT_PATH/prettier.txt"

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "" >&2
  echo "ERROR: some files are not formatted. Run 'make format' (or '$PACKAGE_MANAGER run format') and commit the result." >&2
  echo "The list above is Prettier's own; what is exempt is decided by this project's .prettierignore." >&2
  exit "$EXIT_CODE"
fi

echo "All sources are correctly formatted."
