# terraform.mk -- Terraform pipeline targets (lint, test, test-gen).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/terraform.mk
#
# Targets provided: lint, test, test-gen
# Also sets SEMGREP_LANGUAGE=terraform for the common.mk sast target.
# Note: CodeQL does not support Terraform; CODEQL_LANGUAGE is left unset.
#
# Prerequisites: Terraform CLI >= 1.11 (required for `terraform test
# -junit-xml` output). `terra-cli install` pins a compatible version.

SEMGREP_LANGUAGE ?= terraform

# Where JUnit output lands. Kept consistent with the other runners so
# Azure DevOps / GitLab / GitHub pipelines can `PublishTestResults` from
# a single well-known path.
REPORT_PATH ?= build/reports

.PHONY: lint test test-gen

lint:
	@terraform fmt -recursive -check
	@terraform validate
	@tflint --chdir . --recursive

# `test` drives `terraform test` against `tests/*.tftest.hcl` in the
# current module. Emits JUnit at $(REPORT_PATH)/junit-terra-tests.xml so
# CI can surface per-run results in the Tests tab.
#
# If `tests/` is missing, exits 0 cleanly so modules onboard incrementally
# (matches the opt-in contract used by `terra-test/run.sh` and
# `terratest/run.sh`). Run `make test-gen` first to bootstrap a baseline
# suite via the tftest-gen generator.
test:
	@if [ ! -d tests ] || ! ls tests/*.tftest.hcl >/dev/null 2>&1; then \
		echo "No tests/*.tftest.hcl found; skipping terraform test."; \
		echo "(Run 'make test-gen' to bootstrap a plan-time smoke suite.)"; \
	else \
		mkdir -p "$(REPORT_PATH)" && \
		terraform init -backend=false -input=false -upgrade=false >/dev/null && \
		terraform test -junit-xml="$(REPORT_PATH)/junit-terra-tests.xml"; \
	fi

# `test-gen` generates a baseline `tests/smoke.tftest.hcl` for the current
# module via the shared tftest-gen script. Idempotent — respects
# hand-written tests (marker on line 1).
test-gen:
	@sh "$(SCRIPTS_DIR)/global/scripts/languages/terraform/tftest-gen/run.sh"
