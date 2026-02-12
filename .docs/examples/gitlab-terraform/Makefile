SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines

# -- Project-specific targets --------------------------------------------------

plan:
	terraform plan

apply:
	terraform apply -auto-approve

# -- Pipeline targets (lint, test, sast, secrets, hadolint, trivy, semgrep, security, setup) --

-include $(SCRIPTS_DIR)/makefiles/terraform.mk
-include $(SCRIPTS_DIR)/makefiles/common.mk
