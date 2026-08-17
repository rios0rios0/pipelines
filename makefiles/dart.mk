# dart.mk -- Dart and Flutter language pipeline targets (lint, test, ...).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#   -include $(SCRIPTS_DIR)/makefiles/dart.mk
#
# Targets provided: lint, analyze, test, unused, sca, build, setup-dart
#
# CODEQL_LANGUAGE IS DELIBERATELY NOT SET, and `common.mk`'s `sast` target is
# narrowed below because of it. CodeQL has no Dart extractor at all
# (dart-lang/sdk#52953), so `make codeql` on a Dart project cannot do anything
# but fail. `SEMGREP_LANGUAGE=dart` IS set: the Semgrep engine parses Dart, and
# although the registry publishes no Dart rules (`p/dart` is a 404), the runner
# skips the missing pack and loads this repository's own Dart ruleset instead.
#
# The `sca` target is the Dart counterpart of `make safety` (Python) and
# `govulncheck` (Go): it runs OSV-Scanner over `pubspec.lock` against the Pub
# advisory database.
#
# Prerequisites: none. The Dart or Flutter SDK is installed on demand from
# Google's release archive, and the toolchain is chosen from your pubspec.yaml.

SEMGREP_LANGUAGE ?= dart
export PREFIX ?= .
export REPORT_PATH ?= ./reports

.PHONY: setup-dart lint format analyze test unused sca build sast

setup-dart:
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/setup/run.sh

# `lint` formats in place (the `--fix` mode) and then analyses, matching how the
# other language fragments behave: `make lint` is expected to leave the tree
# clean, not merely to report that it is not.
lint:
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/format/run.sh --fix
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/analyze/run.sh
	-@$(SCRIPTS_DIR)/global/scripts/languages/dart/unused/run.sh

format:
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/format/run.sh --fix

analyze:
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/analyze/run.sh

test:
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/test/run.sh

unused:
	-@$(SCRIPTS_DIR)/global/scripts/languages/dart/unused/run.sh

sca:
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/sca/run.sh

build:
	@$(SCRIPTS_DIR)/global/scripts/languages/dart/build/run.sh

# ADDS the Dart-native SCA to `common.mk`'s `sast` rather than redefining it.
# `sast` there is a prerequisite-only rule (it carries no recipe), so naming it
# again here appends to its prerequisite list -- the documented Make behaviour --
# instead of triggering the "overriding recipe for target" warning a redefinition
# would produce. CodeQL drops out on its own: this file leaves CODEQL_LANGUAGE
# unset, and `common.mk`'s `codeql` target skips with an explanation when it is.
sast: sca
