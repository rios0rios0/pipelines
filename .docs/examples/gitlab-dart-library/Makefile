SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines

# -- Project-specific targets --------------------------------------------------

run:
	dart run

docs:
	dart doc

# -- Pipeline targets (lint, test, sast, sca, cyclonedx, build, setup) ---------
#
# Order matters: `common.mk` first so `dart.mk` can append the Dart-native SCA to
# its `sast` target.

-include $(SCRIPTS_DIR)/makefiles/common.mk
-include $(SCRIPTS_DIR)/makefiles/dart.mk
