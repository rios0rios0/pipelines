TAG := latest
ROOT := global/containers
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

.PHONY: login setup-buildx build build-and-push test lint check-dependency-updates apply-dependency-updates

login:
	docker login $(CONTAINER_REGISTRY)

setup-buildx:
	docker buildx create --use

# The one flag that separates verifying a Dockerfile from publishing it, kept in
# a variable so both targets run the SAME recipe. Two copies of a buildx
# invocation drift, and the copy that drifts is the one nobody runs by hand --
# which is exactly the one a release depends on.
BUILD_OUTPUT = --push

build-and-push:
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		--tag "$(CONTAINER_REGISTRY)/$(NAME):$(TAG)" \
		--file "$(ROOT)/$(NAME).$(TAG)/Dockerfile" \
		$(BUILD_OUTPUT) "$(ROOT)/$(NAME).$(TAG)"

# Both architectures built, nothing published. This is how a container change is
# PROVEN before review: the container delivery had no build-only mode of its own, so
# the only way to find out whether a Dockerfile still builds used to be to push
# the result over the published tag and read the outcome afterwards.
#
# `--output=type=cacheonly` rather than `--load`: `--load` cannot accept a
# multi-platform result at all (it would have to pick one architecture to hand
# the local daemon), and omitting an output entirely makes buildx warn and
# discard the build, which reads like a mistake rather than the intent.
#
# A target-specific variable, not a recursive `$(MAKE)`: GNU Make applies it to
# the prerequisite too, so `build` and `build-and-push` cannot diverge, and NAME,
# TAG and CONTAINER_REGISTRY need no forwarding to stay correct.
build: BUILD_OUTPUT = --output=type=cacheonly
build: build-and-push

# Every validation suite in .github/tests, then the Go helpers' unit tests, through one runner that
# finds the suites itself. `ONLY` runs the named ones: `make test ONLY="workflow-composition
# supply-chain"` (a suite's name is its script's, `test-<name>.sh`, or `go-helpers`).
test:
	@./.github/tests/run.sh $(ONLY)

# Lints the Go helpers with the golden configuration every Go consumer of this library is held to.
# Not part of `make test`: it downloads the pinned golangci-lint, which a test target must not do.
lint:
	@./global/scripts/languages/golang/golangci-lint/run.sh

# Not part of `make test`: it talks to ~40 upstreams over the network, which a unit-test target
# must not do. The scheduled workflow runs it; this target is for running the same check by hand.
check-dependency-updates:
	@./global/scripts/tools/dependency-updates/run.sh

# The same lookups, then every outdated pin rewritten in this working tree -- the change the
# scheduled workflow opens as a pull request, digests and inline copies included -- plus a
# changelog fragment. Commits nothing; review it with `git diff`. Network, like the target above.
apply-dependency-updates:
	@./global/scripts/tools/dependency-updates/run.sh --apply
