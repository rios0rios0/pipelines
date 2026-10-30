# terraform.mk -- Terraform pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/terraform.mk
#
# Targets provided: lint, test
# Also sets SEMGREP_LANGUAGE=terraform for the common.mk sast target, and adds
# common.mk's `checkov` (IaC misconfiguration scanning) to that suite.
# Note: CodeQL does not support Terraform; CODEQL_LANGUAGE is left unset.
#
# Prerequisites: Terraform CLI >= 1.11 (required for `terraform test
# -junit-xml` output). `terra-cli install` pins a compatible version.
# The smoke-suite generator named below needs Go 1.25 or newer: it is built from
# the pipelines checkout on every run (`global/scripts/shared/go-helper.sh`).

SEMGREP_LANGUAGE ?= terraform

# Checkov joins `make sast` for infrastructure code. It is advisory until the
# project sets `CHECKOV_BLOCKING = true`; see the `checkov` target in common.mk.
SAST_TOOLS_EXTRA += checkov

# Where JUnit output lands. Kept consistent with the other runners so
# Azure DevOps / GitLab / GitHub pipelines can `PublishTestResults` from
# a single well-known path.
REPORT_PATH ?= build/reports

.PHONY: lint test

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
# `terratest/run.sh`). To bootstrap a baseline suite, run the tftest-gen
# generator once and commit what it writes -- generating tests is not testing,
# so it is a script rather than a target:
#   "$(SCRIPTS_DIR)/global/scripts/languages/terraform/tftest-gen/run.sh"
# It writes `tests/smoke.tftest.hcl` and never touches a hand-written test.
test:
	@if [ ! -d tests ] || ! ls tests/*.tftest.hcl >/dev/null 2>&1; then \
		echo "No tests/*.tftest.hcl found; skipping terraform test."; \
		echo "(Bootstrap a plan-time smoke suite with \"$(SCRIPTS_DIR)/global/scripts/languages/terraform/tftest-gen/run.sh\".)"; \
	else \
		mkdir -p "$(REPORT_PATH)" && \
		terraform init -backend=false -input=false -upgrade=false >/dev/null && \
		terraform test -junit-xml="$(REPORT_PATH)/junit-terra-tests.xml"; \
	fi
