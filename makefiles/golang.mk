# golang.mk -- Go language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/golang.mk
#
# Targets provided: lint, test, cross-compile, cyclonedx
# Variables provided: VERSION (CHANGELOG-/Git-tag-derived build version)
# Also sets CODEQL_LANGUAGE=go, SEMGREP_LANGUAGE=golang for the common.mk sast target.
# Note: Unused code detection is handled by golangci-lint (unused, unparam, wastedassign linters).

CODEQL_LANGUAGE ?= go
SEMGREP_LANGUAGE ?= golang
export PREFIX ?= .
export REPORT_PATH ?= ./reports

# Default build version for consuming projects' `-X main.version=$(VERSION)` ldflags.
# Resolved from the latest versioned heading in the project's CHANGELOG.md (the
# release source of truth), then the most recent Git tag, and finally "dev". Git
# tags can lag behind the CHANGELOG when a release pipeline is interrupted, so the
# CHANGELOG is preferred. Because this file is included before a project's own
# `VERSION ?=` line, that line becomes a no-op and this value wins; an explicit
# VERSION from the environment or command line still overrides everything.
VERSION ?= $(shell { grep -m1 -oE '^\#\# \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; } || { git describe --tags --abbrev=0 2>/dev/null || echo "dev"; } | sed 's/^v//')

.PHONY: lint test cross-compile cyclonedx

lint:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/golangci-lint/run.sh --fix .

test:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/test/run.sh .

cross-compile:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/cross-compile/run.sh

cyclonedx:
	@$(SCRIPTS_DIR)/global/scripts/languages/golang/cyclonedx/run.sh
