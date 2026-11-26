# python.mk -- Python language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/python.mk
#
# Targets provided: lint, safety, test, cyclonedx
# Also sets CODEQL_LANGUAGE=python, SEMGREP_LANGUAGE=python for the common.mk SAST target.
#
# Prerequisites: PDM must be installed and the project must have a pyproject.toml.

CODEQL_LANGUAGE ?= python
SEMGREP_LANGUAGE ?= python
# The suite `make test-pyramid` (common.mk) judges.
export TEST_PYRAMID_LANGUAGE ?= python
# PREFIX is a directory the scripts put in front of REPORT_PATH (`$PREFIX$REPORT_PATH`), so it is
# empty or ends in `/`, as `lib/` does in the GitLab Java templates. It was `.`, which joined
# `./reports` into `../reports` and wrote a local run's reports outside the project.
export PREFIX ?=
export REPORT_PATH ?= ./reports

.PHONY: lint safety test cyclonedx

lint:
	@pdm run isort .
	@pdm run black .
	@pdm run flake8 .
	@pdm run mypy .
	-@$(SCRIPTS_DIR)/global/scripts/languages/python/vulture/run.sh

safety:
	@pdm run safety

test:
	@pdm run test

cyclonedx:
	@$(SCRIPTS_DIR)/global/scripts/languages/python/cyclonedx/run.sh
