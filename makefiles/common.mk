# common.mk -- Language-agnostic pipeline targets (security, quality, management).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#
# Targets provided: setup codeql semgrep trivy hadolint gitleaks sast unused
# Requires: SCRIPTS_DIR to be set. SEMGREP_LANGUAGE and CODEQL_LANGUAGE should be set by a language
#           .mk file (e.g. golang.mk) or manually before including this file.
# UNUSED_SCRIPT is set automatically by each language .mk file (e.g. golang.mk, python.mk).

UNUSED_SCRIPT ?=

.PHONY: setup codeql semgrep trivy hadolint gitleaks sast unused

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

unused:
# Note: UNUSED_SCRIPT must be set before this target is invoked.
# Language-specific .mk files (golang.mk, python.mk, javascript.mk) set UNUSED_SCRIPT
# and must be included AFTER common.mk to ensure the variable is defined at parse time.
ifdef UNUSED_SCRIPT
	-@$(UNUSED_SCRIPT)
else
	@echo "No unused code scanner configured. Set UNUSED_SCRIPT in your language .mk file."
endif

sast: codeql semgrep trivy hadolint gitleaks unused
