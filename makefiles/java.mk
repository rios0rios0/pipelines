# java.mk -- Java language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/java.mk
#
# Targets provided: lint, test
# Also sets CODEQL_LANGUAGE=java, SEMGREP_LANGUAGE=java for the common.mk sast target.
# Note: Unused code detection is handled by PMD via Gradle/Maven (stage 10, code-check).
# For stricter bytecode-level analysis, configure SpotBugs or ProGuard -printusage in your project.
#
# Prerequisites: Gradle wrapper (gradlew) must be present in the project root.

CODEQL_LANGUAGE ?= java
SEMGREP_LANGUAGE ?= java

.PHONY: lint test

lint:
	@./gradlew check

test:
	@./gradlew test
