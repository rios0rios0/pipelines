# terra.mk -- Terra CLI pipeline targets (lint, test, coverage).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/terra.mk
#
# Targets provided: format, lint, test, test-terra-test, test-terratest, coverage, validate
# Also sets SEMGREP_LANGUAGE=terraform for the common.mk sast target.
# Note: CodeQL does not support Terraform; CODEQL_LANGUAGE is left unset.
#
# Prerequisites: terra CLI (https://github.com/rios0rios0/terra) must be installed.
# Install with: curl -fsSL https://raw.githubusercontent.com/rios0rios0/terra/main/install.sh | sh

SEMGREP_LANGUAGE ?= terraform
REPORT_PATH ?= build/reports

.PHONY: format lint test test-terra-test test-terratest coverage validate

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

# `test` delegates to the unified runner, which orchestrates both tiers
# (`terra-test` over modules + `terratest` over `tests/terratest/`) behind a
# single entry point. Emits per-tier artifacts plus a merged JUnit at
# $(REPORT_PATH)/junit-terra-all.xml and a Cobertura coverage summary at
# $(REPORT_PATH)/terra-coverage.xml. Exits 0 cleanly when neither tier has
# tests, so stack-only repos don't need a bespoke opt-out.
test:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/test-all/run.sh

# `test-terra-test` and `test-terratest` still work as escape hatches for
# operators who want to exercise one tier at a time (e.g., during debugging
# of a misbehaving terratest suite without re-running the full `terraform
# test` matrix). The default `test` target covers both tiers.
test-terra-test:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/terra-test/run.sh

test-terratest:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/terratest/run.sh

coverage:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/test-all/run.sh || true
	@echo "Coverage reports: $(REPORT_PATH)/terra-coverage.md $(REPORT_PATH)/junit-terra-all.xml"

validate: format lint test
	@echo "All validations passed (format, lint, test)."
