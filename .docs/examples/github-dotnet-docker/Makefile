SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines

# -- Project-specific targets --------------------------------------------------

build:
	dotnet build

run:
	dotnet run

# -- Pipeline targets (lint, test, sast, secrets, hadolint, trivy, semgrep, security, setup) --

-include $(SCRIPTS_DIR)/makefiles/dotnet.mk
-include $(SCRIPTS_DIR)/makefiles/common.mk
