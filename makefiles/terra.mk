# terra.mk -- Terra CLI pipeline targets (lint, test, coverage).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/terra.mk
#
# Targets provided: format, lint, test, coverage, validate
# Also sets SEMGREP_LANGUAGE=terraform for the common.mk sast target.
# Note: CodeQL does not support Terraform; CODEQL_LANGUAGE is left unset.
#
# Prerequisites: terra CLI (https://github.com/rios0rios0/terra) must be installed.
# Install with: curl -fsSL https://raw.githubusercontent.com/rios0rios0/terra/main/install.sh | sh

SEMGREP_LANGUAGE ?= terraform
REPORT_PATH ?= build/reports

.PHONY: format lint test coverage validate

format:
	@echo "Formatting Terraform files with Terra..."
	@terra format
	@echo "Checking for unformatted files..."
	@git diff --exit-code || (echo "ERROR: Files were not formatted. Run 'make format' and commit the changes." && exit 1)
	@echo "Format check passed."

lint:
	@echo "Linting Terraform files with TFLint..."
	@tflint --chdir . --recursive
	@echo "Lint check passed."

# `test` delegates to the shared runner, which emits one JUnit file per
# module under $(REPORT_PATH)/terra-tests/, an aggregated JUnit bundle at
# $(REPORT_PATH)/terra-tests.xml (for PublishTestResults@2), and a coverage
# summary at $(REPORT_PATH)/terra-coverage.{md,json}. Consumers that want
# the report without failing on a red build call `make coverage` instead,
# which re-runs the same script but never exits non-zero.
test:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/terra-test/run.sh

coverage:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/terra-test/run.sh || true
	@echo "Coverage report: $(REPORT_PATH)/terra-coverage.md"

validate: format lint test
	@echo "All validations passed (format, lint, test)."
