# java.mk -- Java language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/java.mk
#
# Targets provided: lint, test, proguard
# Also sets CODEQL_LANGUAGE=java, SEMGREP_LANGUAGE=java for the common.mk sast target.
# Note: Stage 10 PMD (via Gradle/Maven) handles source-level unused code detection.
# ProGuard provides bytecode-level whole-program dead code analysis in stage 20.
#
# Prerequisites: Gradle wrapper (gradlew) must be present in the project root.

CODEQL_LANGUAGE ?= java
SEMGREP_LANGUAGE ?= java
UNUSED_SCRIPT ?= $(SCRIPTS_DIR)/global/scripts/languages/java/proguard/run.sh

.PHONY: lint test proguard

lint:
	@./gradlew check

test:
	@./gradlew test

proguard:
	-@$(SCRIPTS_DIR)/global/scripts/languages/java/proguard/run.sh
