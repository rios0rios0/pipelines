# terra.mk -- Terra CLI pipeline targets (format, lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/terra.mk
#
# Targets provided: format, lint, test
# Also sets SEMGREP_LANGUAGE=terraform for the common.mk sast target, and adds
# common.mk's `checkov` (IaC misconfiguration scanning) to that suite.
# Note: CodeQL does not support Terraform; CODEQL_LANGUAGE is left unset.
#
# Prerequisites: terra CLI (https://github.com/rios0rios0/terra) must be installed.
# Install with: curl -fsSL https://raw.githubusercontent.com/rios0rios0/terra/main/install.sh | sh

SEMGREP_LANGUAGE ?= terraform

# Checkov joins `make sast` for infrastructure code. It is advisory until the
# project sets `CHECKOV_BLOCKING = true`; see the `checkov` target in common.mk.
SAST_TOOLS_EXTRA += checkov
REPORT_PATH ?= build/reports

.PHONY: format lint test

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

# `test` runs every test tier through one script, `terraform/test-all/run.sh`:
#   terra-test  `terraform test` over `modules/*/tests/*.tftest.hcl`
#   terratest   the Go suite under `tests/terratest/`
#   structural  the repository's own `tests/structural.sh`
#   validate    `terraform validate` over the root modules under `VALIDATE_ROOTS` (default
#               `stacks`), only with `ENABLE_VALIDATE=true`: unlike the other tiers it needs the
#               network for providers and, for private module sources, credentials
# `ONLY` runs some of them: `make test ONLY=structural`. A tier with nothing to run passes, so a
# stack-only repository needs no opt-out. Reports land in $(REPORT_PATH): a merged JUnit at
# junit-terra-all.xml, and the coverage of the terra-test tier as terra-coverage.{md,json,xml} and,
# for SonarQube, terra-coverage-generic.xml.
#
# Set `TERRA_TEST_ROOTS` (space-separated, empty by default, e.g. `stacks`) to also run the root
# modules' own `tests/*.tftest.hcl`: `make test TERRA_TEST_ROOTS=stacks`. A root's run blocks must
# set `command = plan`, or the file declare a `mock_provider`, since a run block otherwise APPLIES
# with the root's real providers; a root whose tests would apply is refused and fails the target.
test:
	@REPORT_PATH=$(REPORT_PATH) TERRA_TEST_TIERS="$(ONLY)" $(SCRIPTS_DIR)/global/scripts/languages/terraform/test-all/run.sh
