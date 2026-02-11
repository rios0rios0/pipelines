# dotnet.mk -- .NET/C# language pipeline targets (lint, test).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/dotnet.mk
#
# Targets provided: lint, test
# Also sets CODEQL_LANGUAGE=csharp, SEMGREP_LANGUAGE=csharp for the common.mk sast target.
#
# Prerequisites: .NET SDK must be installed.

CODEQL_LANGUAGE ?= csharp
SEMGREP_LANGUAGE ?= csharp

.PHONY: lint test

lint:
	@dotnet format

test:
	@dotnet test
