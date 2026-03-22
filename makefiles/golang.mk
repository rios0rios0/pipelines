# golang.mk -- Go language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/golang.mk
#
# Targets provided: lint, test, cross-compile, cyclonedx, deadcode
# Also sets CODEQL_LANGUAGE=go, SEMGREP_LANGUAGE=golang for the common.mk sast target.
# Sets UNUSED_SCRIPT to the deadcode runner for the common.mk unused target.

CODEQL_LANGUAGE ?= go
SEMGREP_LANGUAGE ?= golang
UNUSED_SCRIPT = $(SCRIPTS_DIR)/global/scripts/languages/golang/deadcode/run.sh
export PREFIX ?= .
export REPORT_PATH ?= ./reports

.PHONY: lint test cross-compile cyclonedx deadcode

lint:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/golangci-lint/run.sh --fix .

test:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/test/run.sh .

cross-compile:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/cross-compile/run.sh

cyclonedx:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/cyclonedx/run.sh

deadcode:
	-@$(SCRIPTS_DIR)/global/scripts/languages/golang/deadcode/run.sh
