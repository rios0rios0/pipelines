# common.mk -- Language-agnostic pipeline targets (security, quality, management).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#
# Targets provided: sast
# Requires: SCRIPTS_DIR to be set. SEMGREP_LANGUAGE and CODEQL_LANGUAGE should be set by a language
#           .mk file (e.g. golang.mk) or manually before including this file.

.PHONY: setup sast

setup:
	@curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash

sast:
	@$(SCRIPTS_DIR)/global/scripts/tools/codeql/run.sh "$(CODEQL_LANGUAGE)"
	@$(SCRIPTS_DIR)/global/scripts/tools/semgrep/run.sh "$(SEMGREP_LANGUAGE)"
	@$(SCRIPTS_DIR)/global/scripts/tools/trivy/run.sh
	@$(SCRIPTS_DIR)/global/scripts/tools/hadolint/run.sh
	@$(SCRIPTS_DIR)/global/scripts/tools/gitleaks/run.sh
