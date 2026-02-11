SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines

# -- Project-specific targets --------------------------------------------------

build:
	go build -o bin/app .

run:
	go run .

# -- Pipeline targets (lint, test, sast, secrets, hadolint, trivy, semgrep, security, setup) --

-include $(SCRIPTS_DIR)/makefiles/golang.mk
-include $(SCRIPTS_DIR)/makefiles/common.mk
