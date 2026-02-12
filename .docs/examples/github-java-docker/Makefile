SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines

# -- Project-specific targets --------------------------------------------------

build:
	./gradlew build -x test

run:
	./gradlew bootRun

# -- Pipeline targets (lint, test, sast, secrets, hadolint, trivy, semgrep, security, setup) --

-include $(SCRIPTS_DIR)/makefiles/java.mk
-include $(SCRIPTS_DIR)/makefiles/common.mk
