# javascript.mk -- JavaScript/Node.js language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/javascript.mk
#
# Targets provided: lint, format, test
# Also sets CODEQL_LANGUAGE=javascript, SEMGREP_LANGUAGE=javascript for the common.mk sast target.
#
# Prerequisites: Yarn must be installed and the project must have a package.json.

CODEQL_LANGUAGE ?= javascript
SEMGREP_LANGUAGE ?= javascript

.PHONY: lint format test

# `lint` formats in place (the `--fix` mode) and then lints, matching `dart.mk`:
# `make lint` is expected to LEAVE the tree clean, not merely to report that it is
# not. The formatter runs first so ESLint sees the formatted text -- and because
# almost every JavaScript project installs `eslint-config-prettier`, which switches
# off every ESLint rule that overlaps with Prettier, `yarn lint` alone says nothing
# about formatting at all. The `style:format` CI job is the gate for the same
# reason.
#
# Skipped silently on a project that does not use Prettier; see the runner.
lint:
	@$(SCRIPTS_DIR)/global/scripts/languages/javascript/format/run.sh --fix
	@yarn lint
	-@$(SCRIPTS_DIR)/global/scripts/languages/javascript/knip/run.sh

format:
	@$(SCRIPTS_DIR)/global/scripts/languages/javascript/format/run.sh --fix

test:
	@yarn test
