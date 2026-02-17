# terra.mk -- Terra CLI pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/terra.mk
#
# Targets provided: lint, test
# Also sets SEMGREP_LANGUAGE=terraform for the common.mk sast target.
# Note: CodeQL does not support Terraform; CODEQL_LANGUAGE is left unset.
#
# Prerequisites: terra CLI (https://github.com/rios0rios0/terra) must be installed.
# Install with: curl -fsSL https://raw.githubusercontent.com/rios0rios0/terra/main/install.sh | sh

SEMGREP_LANGUAGE ?= terraform

.PHONY: lint test

lint:
	@terra format
	@echo "Checking for unformatted files..."
	@git diff --exit-code || (echo "ERROR: Files were not formatted. Run 'make lint' and commit the changes." && exit 1)

test:
	@if [ -d "modules" ]; then \
		for module in modules/*/; do \
			if [ -d "$$module/tests" ]; then \
				echo "Testing $$module..."; \
				(cd "$$module" && terraform init -upgrade && terraform test) || exit 1; \
			else \
				echo "Skipping $${module%/} (no tests/ directory)."; \
			fi; \
		done; \
		echo "All module tests passed."; \
	else \
		echo "No modules/ directory found, skipping tests."; \
	fi
