# python.mk -- Python language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/python.mk
#
# Targets provided: lint, test
# Also sets CODEQL_LANGUAGE=python, SEMGREP_LANGUAGE=python for the common.mk sast target.
#
# Prerequisites: PDM must be installed and the project must have a pyproject.toml.

CODEQL_LANGUAGE ?= python
SEMGREP_LANGUAGE ?= python

.PHONY: lint test

lint:
	@pdm run isort .
	@pdm run black .
	@pdm run flake8 .
	@pdm run mypy .

test:
	@pdm run test
