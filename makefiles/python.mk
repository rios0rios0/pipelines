# python.mk -- Python language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/python.mk
#
# Targets provided: lint, safety, test, cyclonedx, vulture
# Also sets CODEQL_LANGUAGE=python, SEMGREP_LANGUAGE=python for the common.mk SAST target.
# Sets UNUSED_SCRIPT to the vulture runner for the common.mk unused target.
#
# Prerequisites: PDM must be installed and the project must have a pyproject.toml.

CODEQL_LANGUAGE ?= python
SEMGREP_LANGUAGE ?= python
UNUSED_SCRIPT = $(SCRIPTS_DIR)/global/scripts/languages/python/vulture/run.sh
export PREFIX ?= .
export REPORT_PATH ?= ./reports


.PHONY: lint safety test cyclonedx vulture

lint:
	@pdm run isort .
	@pdm run black .
	@pdm run flake8 .
	@pdm run mypy .

safety:
	@pdm run safety

test:
	@pdm run test

cyclonedx:
	@$(SCRIPTS_DIR)/global/scripts/languages/python/cyclonedx/run.sh

vulture:
	-@$(SCRIPTS_DIR)/global/scripts/languages/python/vulture/run.sh

