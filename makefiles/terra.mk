# terra.mk -- Terra CLI pipeline targets (lint, test, coverage).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/terra.mk
#
# Targets provided: format, lint, test, test-terra-test, test-terratest, test-structural, coverage, validate
# Also sets SEMGREP_LANGUAGE=terraform for the common.mk sast target.
# Note: CodeQL does not support Terraform; CODEQL_LANGUAGE is left unset.
#
# Prerequisites: terra CLI (https://github.com/rios0rios0/terra) must be installed.
# Install with: curl -fsSL https://raw.githubusercontent.com/rios0rios0/terra/main/install.sh | sh

SEMGREP_LANGUAGE ?= terraform
REPORT_PATH ?= build/reports

.PHONY: format lint test test-terra-test test-terratest test-structural coverage validate

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

# `test-structural` runs the consumer's `tests/structural.sh` (if any) and
# emits `$(REPORT_PATH)/junit-structural.xml`. The script is consumer-owned
# because repo conventions vary — the runner is just the glue. No-op when
# `tests/structural.sh` is absent, so stack-only / convention-free repos
# don't need a bespoke opt-out.
test-structural:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/structural/run.sh

coverage:
	@REPORT_PATH=$(REPORT_PATH) $(SCRIPTS_DIR)/global/scripts/languages/terraform/test-all/run.sh || true
	@artifacts=""; \
	for report in "$(REPORT_PATH)/terra-coverage.md" "$(REPORT_PATH)/terra-coverage.xml" "$(REPORT_PATH)/terra-coverage.json" "$(REPORT_PATH)/junit-terra-all.xml"; do \
		if [ -f "$$report" ]; then \
			artifacts="$$artifacts $$report"; \
		fi; \
	done; \
	if [ -n "$$artifacts" ]; then \
		echo "Coverage reports:$$artifacts"; \
	else \
		echo "Coverage reports: none generated"; \
	fi

validate: format lint test
	@echo "All validations passed (format, lint, test)."
