# common.mk -- Language-agnostic pipeline targets (security, quality, management).
#
# Usage: Add the following to your project's Makefile:
#   SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
#   -include $(SCRIPTS_DIR)/makefiles/common.mk
#
# Targets provided: setup codeql semgrep hadolint shellcheck gitleaks sast
#                   gitignore gitignore-check
# Requires: SCRIPTS_DIR to be set. SEMGREP_LANGUAGE and CODEQL_LANGUAGE should be set by a language
#           .mk file (e.g. golang.mk) or manually before including this file.
#
# EVERY TARGET HERE FAILS WHEN ITS TOOL FAILS. `sast` runs the whole suite even
# when one tool reports findings, and then exits non-zero with a `SAST FAILED:`
# line naming which ones did -- so `make lint && make sast` is a gate that can
# actually stop a push. See the block above `codeql` for why, and for where the
# advisory-versus-blocking decision belongs instead.
#
# Variables: SAST_TOOLS       the suite `sast` runs (override to narrow it)
#            SAST_TOOLS_EXTRA appended to by language fragments; never set here

.PHONY: setup codeql semgrep hadolint shellcheck gitleaks sast gitignore gitignore-check

# Bootstraps the local checkout of this repository that every other target
# reads its scripts from.
#
# This used to be `curl -sSL .../clone.sh | bash`. That is the same
# pipe-a-remote-script-into-a-shell shape the SAST stage of this repository
# flags in consumers' code, and it was the FIRST command a new developer ran --
# fetched from a branch, unpinned, unverified, executed with their own user's
# privileges on their own workstation. `clone.sh` only ever ran `git clone` or
# `git pull --ff-only`, so doing that directly is behaviour-identical and
# fetches no remote script at all. `clone.sh` remains for anyone who wants the
# documented one-liner, but nothing in this repository depends on it any more.
PIPELINES_HOME ?= $(HOME)/Development/github.com/rios0rios0/pipelines
PIPELINES_REPO ?= https://github.com/rios0rios0/pipelines.git

setup:
	@if [ -d "$(PIPELINES_HOME)/.git" ]; then \
		echo "Updating pipelines repository at $(PIPELINES_HOME)..."; \
		git -C "$(PIPELINES_HOME)" pull --ff-only; \
	else \
		echo "Cloning pipelines repository to $(PIPELINES_HOME)..."; \
		mkdir -p "$$(dirname "$(PIPELINES_HOME)")"; \
		git clone "$(PIPELINES_REPO)" "$(PIPELINES_HOME)"; \
	fi

# EXIT CODES ARE THE POINT OF THESE TARGETS, so none of the recipes below
# suppresses one.
#
# Every recipe here used to carry a `-` prefix, and `codeql` a trailing
# `|| true`, which tell Make to ignore the recipe's exit status. That was a
# deliberate change and its reason was sound -- the commit that made it says
# "so the aggregate `sast` target runs all tools to completion", because a
# prerequisite-only `sast` stops at the FIRST tool that fails, and a repository
# with a Semgrep finding then never learns it has a Gitleaks one too. The
# intent was right. The mechanism threw away far more than the intent needed.
#
# What it cost: `make sast` and every individual SAST target exited 0
# unconditionally -- on findings, on a crash, and on termination. Real runs
# printed `Error 123 (ignored)` from ShellCheck and `Terminated (ignored)` from
# an out-of-memory Semgrep, and then reported success. Everything keyed to the
# exit code inherited that blind spot: a `make sast && git push` habit (whose
# `&&` can never short-circuit), a pre-push hook, and any consumer that wired
# the target into its own CI. A gate that cannot fail is worse than no gate,
# because it is trusted.
#
# Propagating is safe because every `run.sh` under `global/scripts/tools/`
# already returns a MEANINGFUL code rather than a raw tool code, and each one
# owns a project-level suppression file for findings a team has triaged:
#
#   codeql      non-zero only when results REMAIN after the fingerprints in
#               `.codeql-false-positives` are subtracted; `exit 1` when the
#               scan itself broke (database create, analyze, or missing SARIF)
#   semgrep     run with `--error`, so non-zero on a finding; `.semgrepignore`
#               and `.semgrepexcluderules` narrow what counts as one
#   hadolint    non-zero on a finding; `.hadolint.yaml` selects the rules
#   shellcheck  already floored at `--severity=warning`, so info and style
#               findings never reach it; 123 is `xargs` reporting that some
#               file had a finding, not a separate failure mode
#   gitleaks    non-zero on a leak; `.gitleaksignore` fingerprints allowlist
#               the triaged ones, and the scan is scoped to this build's own
#               commits rather than every ref in the clone
#
# So "too noisy to block on" is already answered where the noise is -- per
# tool, per project, in a reviewable file -- rather than by blinding the caller.
#
# WHERE ADVISORY-VERSUS-BLOCKING IS DECIDED: at the call site, which already
# decides it, differently per platform. `azure-devops/global/stages/20-security/`
# marks all five `continueOnError: true`; `.github/workflows/*.yaml` forgives
# `hadolint` with `continue-on-error: true` and blocks on the rest; GitLab
# blocks on all five. Three deliberate policies, each owned by the pipeline
# that holds it. A makefile that swallows the code cannot express any of them
# and silently overrides all three. These targets report what happened; the
# caller decides what it should mean. A consumer that wants the old behaviour
# writes `make sast || true` at its own call site, where the decision is
# visible in review.

# Skipped, with an explanation, when no language is configured. Not every
# language this repository supports HAS a CodeQL extractor -- Dart notably does
# not (dart-lang/sdk#52953) -- and its `.mk` fragment signals that by leaving
# CODEQL_LANGUAGE unset. Without this guard the run script rejects the empty
# argument with a bare usage message that reads like a misconfiguration, on
# every `make sast` of such a project.
# The emptiness test lives in the RECIPE, not in a make-level `ifeq`. A
# conditional is evaluated while the makefile is being parsed, and this file is
# included BEFORE the language fragment that sets CODEQL_LANGUAGE -- so an
# `ifeq` here reads the variable while it is still empty and takes the skip
# branch for EVERY language, silently disabling CodeQL repository-wide. Recipe
# text is expanded at execution time, once every include has been read, which is
# the only point at which the value is trustworthy.
codeql:
	@if [ -z "$(strip $(CODEQL_LANGUAGE))" ]; then \
	  echo "CODEQL_LANGUAGE is not set; skipping CodeQL (no extractor for this language)."; \
	else \
	  $(SCRIPTS_DIR)/global/scripts/tools/codeql/run.sh "$(CODEQL_LANGUAGE)"; \
	fi

semgrep:
	@$(SCRIPTS_DIR)/global/scripts/tools/semgrep/run.sh "$(SEMGREP_LANGUAGE)"

hadolint:
	@$(SCRIPTS_DIR)/global/scripts/tools/hadolint/run.sh

shellcheck:
	@$(SCRIPTS_DIR)/global/scripts/tools/shellcheck/run.sh

gitleaks:
	@$(SCRIPTS_DIR)/global/scripts/tools/gitleaks/run.sh

# The tools `sast` runs, by target name. Overridable, so a project can narrow
# the suite; a LANGUAGE FRAGMENT adds to `SAST_TOOLS_EXTRA` instead (see
# `dart.mk`, which appends its `sca` target).
#
# Two variables rather than one because include order must not matter. With a
# single `SAST_TOOLS ?=` here and `+=` in the fragment, a project that included
# `dart.mk` FIRST would leave the variable already set when this file is read,
# the `?=` would decline to set the default, and `sast` would silently run
# OSV-Scanner alone -- a scan that reports success having skipped every SAST
# tool, which is the same class of quiet failure this whole block exists to
# remove. `SAST_TOOLS_EXTRA` is only ever appended to and only ever read, so
# both orders produce the same suite.
SAST_TOOLS ?= codeql semgrep hadolint shellcheck gitleaks

# Runs every tool, then fails ONCE if any of them did. This keeps the
# run-to-completion behaviour the `-` prefixes were introduced for, without the
# unconditional success they also bought: one `make sast` still reports every
# tool's findings in a single pass, and still exits non-zero when there are any.
#
# One `$(MAKE)` per tool rather than a second copy of each invocation. The
# recipes above stay the single definition, so the standalone target and the
# aggregate cannot drift -- the same reason the root Makefile keeps one buildx
# recipe behind a variable. `-f $(firstword $(MAKEFILE_LIST))` is the including
# project's own makefile: Make does not pass `-f` down to a sub-make, so without
# it a project whose makefile is not named `Makefile` would have every sub-make
# die with "No rule to make target". Recipe lines containing `$(MAKE)` are still
# executed under `--dry-run`, so `make -n sast` keeps printing each tool's real
# command rather than just this loop.
#
# The verdict line is the requirement, not a flourish. The documented pre-push
# gate is `make lint && make sast`, and an engineer has to be able to tell
# success from failure from the LAST line -- not by re-reading the scrollback of
# five tools hunting for an "(ignored)" nobody told them to look for.
sast:
	@failed=''; \
	for tool in $(SAST_TOOLS) $(SAST_TOOLS_EXTRA); do \
	  $(MAKE) -f $(firstword $(MAKEFILE_LIST)) --no-print-directory "$$tool" \
	    || failed="$$failed $$tool"; \
	done; \
	if [ -n "$$failed" ]; then \
	  echo "" >&2; \
	  echo "SAST FAILED:$$failed" >&2; \
	  echo "Reports are under $${REPORT_PATH:-build/reports}/. Fix the findings, or record the" >&2; \
	  echo "ones you have triaged in that tool's suppression file (.codeql-false-positives," >&2; \
	  echo ".semgrepignore, .semgrepexcluderules, .hadolint.yaml, .gitleaksignore)." >&2; \
	  exit 1; \
	fi; \
	echo ""; \
	echo "SAST PASSED: $(SAST_TOOLS) $(SAST_TOOLS_EXTRA)"

# Keeps the shared ignore rules in this project's `.gitignore`.
#
# The pipeline writes report files into the consumer's working tree, and until now
# each consumer had to know their names and track them by hand -- so a script that
# started writing a new report leaked it into every repository at once, silently.
# These rules are generated from `global/gitignore/` instead. `gitignore` rewrites the
# delimited block, `gitignore-check` fails when it is stale; wire the latter into a
# pull request check so drift cannot accumulate again.
#
# Git has no `include` for ignore files and refuses to follow a symlinked
# `.gitignore`, and the mechanisms that do take an external file are local to a clone
# -- invisible to CI and to any bot that clones and runs `git add -A`. Generating a
# committed block is what survives that.
gitignore:
	@$(SCRIPTS_DIR)/global/scripts/tools/gitignore/run.sh .

gitignore-check:
	@$(SCRIPTS_DIR)/global/scripts/tools/gitignore/run.sh --check .
