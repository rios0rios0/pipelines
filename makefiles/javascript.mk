# javascript.mk -- JavaScript/Node.js language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/javascript.mk
#
# Targets provided: lint, test, knip
# Also sets CODEQL_LANGUAGE=javascript, SEMGREP_LANGUAGE=javascript for the common.mk sast target.
# Sets UNUSED_SCRIPT to the knip runner for the common.mk unused target.
#
# Prerequisites: Yarn must be installed and the project must have a package.json.

CODEQL_LANGUAGE ?= javascript
SEMGREP_LANGUAGE ?= javascript
UNUSED_SCRIPT = $(SCRIPTS_DIR)/global/scripts/languages/javascript/knip/run.sh

.PHONY: lint test knip

lint:
	@yarn lint

test:
	@yarn test

knip:
	-@$(SCRIPTS_DIR)/global/scripts/languages/javascript/knip/run.sh
