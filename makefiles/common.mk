# common.mk -- Language-agnostic pipeline targets (security, quality, management).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#
# Targets provided: setup codeql semgrep hadolint shellcheck gitleaks sast
# Requires: SCRIPTS_DIR to be set. SEMGREP_LANGUAGE and CODEQL_LANGUAGE should be set by a language
#           .mk file (e.g. golang.mk) or manually before including this file.

.PHONY: setup codeql semgrep hadolint shellcheck gitleaks sast

# Bootstraps the local checkout of this repository that every other target
# reads its scripts from.
#
# This used to be `curl -sSL .../clone.sh | bash`. That is the same
# pipe-a-remote-script-into-a-shell shape the SAST stage of this repository
# flags in consumers' code, and it was the FIRST command a new developer ran --
# fetched from a branch, unpinned, unverified, executed with their own user's
# privileges on their own workstation. `clone.sh` only ever ran `git clone` or
# `git pull --ff-only`, so doing that directly is behaviour-identical and
# fetches no remote script at all. `clone.sh` remains for anyone who wants the
# documented one-liner, but nothing in this repository depends on it any more.
PIPELINES_HOME ?= $(HOME)/Development/github.com/rios0rios0/pipelines
PIPELINES_REPO ?= https://github.com/rios0rios0/pipelines.git

setup:
	@if [ -d "$(PIPELINES_HOME)/.git" ]; then \
		echo "Updating pipelines repository at $(PIPELINES_HOME)..."; \
		git -C "$(PIPELINES_HOME)" pull --ff-only; \
	else \
		echo "Cloning pipelines repository to $(PIPELINES_HOME)..."; \
		mkdir -p "$$(dirname "$(PIPELINES_HOME)")"; \
		git clone "$(PIPELINES_REPO)" "$(PIPELINES_HOME)"; \
	fi

# Skipped, with an explanation, when no language is configured. Not every
# language this repository supports HAS a CodeQL extractor -- Dart notably does
# not (dart-lang/sdk#52953) -- and its `.mk` fragment signals that by leaving
# CODEQL_LANGUAGE unset. Without this guard the run script rejects the empty
# argument with a bare usage message that reads like a misconfiguration, on
# every `make sast` of such a project.
# The emptiness test lives in the RECIPE, not in a make-level `ifeq`. A
# conditional is evaluated while the makefile is being parsed, and this file is
# included BEFORE the language fragment that sets CODEQL_LANGUAGE -- so an
# `ifeq` here reads the variable while it is still empty and takes the skip
# branch for EVERY language, silently disabling CodeQL repository-wide. Recipe
# text is expanded at execution time, once every include has been read, which is
# the only point at which the value is trustworthy.
codeql:
	@if [ -z "$(strip $(CODEQL_LANGUAGE))" ]; then \
	  echo "CODEQL_LANGUAGE is not set; skipping CodeQL (no extractor for this language)."; \
	else \
	  $(SCRIPTS_DIR)/global/scripts/tools/codeql/run.sh "$(CODEQL_LANGUAGE)" || true; \
	fi

semgrep:
	-@$(SCRIPTS_DIR)/global/scripts/tools/semgrep/run.sh "$(SEMGREP_LANGUAGE)"

hadolint:
	-@$(SCRIPTS_DIR)/global/scripts/tools/hadolint/run.sh

shellcheck:
	-@$(SCRIPTS_DIR)/global/scripts/tools/shellcheck/run.sh

gitleaks:
	-@$(SCRIPTS_DIR)/global/scripts/tools/gitleaks/run.sh

sast: codeql semgrep hadolint shellcheck gitleaks
