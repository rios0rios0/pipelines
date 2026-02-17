# common.mk -- Language-agnostic pipeline targets (security, quality, management).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#
# Targets provided: setup codeql semgrep trivy hadolint gitleaks sast
# Requires: SCRIPTS_DIR to be set. SEMGREP_LANGUAGE and CODEQL_LANGUAGE should be set by a language
#           .mk file (e.g. golang.mk) or manually before including this file.

.PHONY: setup codeql semgrep trivy hadolint gitleaks sast

setup:
	@curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash

codeql:
	-@$(SCRIPTS_DIR)/global/scripts/tools/codeql/run.sh "$(CODEQL_LANGUAGE)"

semgrep:
	-@$(SCRIPTS_DIR)/global/scripts/tools/semgrep/run.sh "$(SEMGREP_LANGUAGE)"

trivy:
	-@$(SCRIPTS_DIR)/global/scripts/tools/trivy/run.sh

hadolint:
	-@$(SCRIPTS_DIR)/global/scripts/tools/hadolint/run.sh

gitleaks:
	-@$(SCRIPTS_DIR)/global/scripts/tools/gitleaks/run.sh

sast: codeql semgrep trivy hadolint gitleaks
