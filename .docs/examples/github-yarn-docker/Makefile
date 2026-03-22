SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines

# -- Project-specific targets --------------------------------------------------

build:
	yarn build

dev:
	yarn dev

# -- Pipeline targets (lint, test, sast, secrets, hadolint, trivy, semgrep, security, setup) --

-include $(SCRIPTS_DIR)/makefiles/javascript.mk
-include $(SCRIPTS_DIR)/makefiles/common.mk
