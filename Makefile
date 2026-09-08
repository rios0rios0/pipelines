TAG := latest
ROOT := global/containers
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

.PHONY: login setup-buildx build build-and-push test-dependency-track test-go-script test-cyclonedx-main test-go-cache-trim test-go-tmpdir-modcache test-go-integration-scope test-lambda test-yaml-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-order-check test-var-catalog test-terraform-validate test-terraform-provider-mirror test-docker-multi-arch test-containers-detect test-basic-checks test-gitignore test-dependency-check test-goreleaser-prepare test-release-version-extraction test-release-reconcile test-deploy-providers test-memory-detection test-dart-pipeline test-javascript-pipeline test-terra-pipeline test-workflow-composition test-working-directory test-supply-chain test-runner-cache-gating test-azure-step-names test-dependency-updates test-go-module-toolchain check-dependency-updates test

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
# PROVEN before review: `Container Images` has no build-only mode of its own, so
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

# Test targets
test-go-script:
	@echo "Running Go test script validation..."
	@./.github/tests/test-go-validation.sh

test-cyclonedx-main:
	@echo "Running Go CycloneDX entry-point detection validation..."
	@./.github/tests/test-cyclonedx-main-detection.sh

test-go-cache-trim:
	@echo "Running Go build-cache disk guard validation..."
	@./.github/tests/test-go-cache-trim.sh

test-go-tmpdir-modcache:
	@echo "Running Go module cache placement validation..."
	@./.github/tests/test-go-tmpdir-modcache.sh

test-go-integration-scope:
	@echo "Running Go integration phase scope validation..."
	@./.github/tests/test-go-integration-scope.sh

test-go-tool-staleness:
	@echo "Running Go source-built tool staleness validation..."
	@./.github/tests/test-go-tool-staleness.sh

test-lambda:
	@echo "Running Lambda template validation..."
	@./.github/tests/test-lambda-templates.sh

test-yaml-merge:
	@echo "Running YAML merge validation..."
	@./.github/tests/test-yaml-merge.sh

test-sonarqube:
	@echo "Running SonarQube auto-derivation validation..."
	@./.github/tests/test-sonarqube-auto-derive.sh

test-release-tag-idempotency:
	@echo "Running release tag idempotency validation..."
	@./.github/tests/test-release-tag-idempotency.sh

test-tftest-gen:
	@echo "Running tftest-gen generator validation..."
	@./.github/tests/test-tftest-gen.sh

test-order-check:
	@echo "Running terraform order-check validation..."
	@./.github/tests/test-order-check.sh

test-var-catalog:
	@echo "Running terraform var-catalog generator validation..."
	@./.github/tests/test-var-catalog.sh

test-terraform-validate:
	@echo "Running terraform validate tier validation..."
	@./.github/tests/test-terraform-validate.sh

test-terraform-provider-mirror:
	@echo "Running Terraform provider mirror validation..."
	@./.github/tests/test-terraform-provider-mirror.sh

test-docker-multi-arch:
	@echo "Running 40-delivery/docker multi-arch contract validation..."
	@./.github/tests/test-docker-multi-arch.sh

test-containers-detect:
	@echo "Running Container Images change-detection validation..."
	@./.github/tests/test-containers-detect.sh

test-basic-checks:
	@echo "Running basic-checks changelog validation..."
	@./.github/tests/test-basic-checks.sh

test-gitignore:
	@echo "Running shared .gitignore block generator tests..."
	@./.github/tests/test-gitignore.sh

test-dependency-check:
	@echo "Running OWASP Dependency-Check NVD cache/API-key validation..."
	@./.github/tests/test-dependency-check.sh

test-dependency-track:
	@echo "Running Dependency-Track BOM uploader validation..."
	@./.github/tests/test-dependency-track.sh

test-goreleaser-prepare:
	@echo "Running GoReleaser main package detection validation..."
	@./.github/tests/test-goreleaser-prepare.sh

test-release-version-extraction:
	@echo "Running release version extraction validation..."
	@./.github/tests/test-release-version-extraction.sh

test-release-reconcile:
	@echo "Running release reconciliation validation..."
	@./.github/tests/test-release-reconcile.sh

test-release-promotion:
	@echo "Running release promotion validation..."
	@./.github/tests/test-release-promotion.sh

test-deploy-providers:
	@echo "Running MVP hosting deployment provider validation..."
	@./.github/tests/test-deploy-providers.sh

test-memory-detection:
	@echo "Running memory ceiling detection validation..."
	@./.github/tests/test-memory-detection.sh

test-dart-pipeline:
	@echo "Running Dart/Flutter pipeline validation..."
	@./.github/tests/test-dart-pipeline.sh

test-terra-pipeline:
	@echo "Running Terraform pipeline validation..."
	@./.github/tests/test-terra-pipeline.sh

test-javascript-pipeline:
	@echo "Running JavaScript formatting-gate validation..."
	@./.github/tests/test-javascript-pipeline.sh

test-workflow-composition:
	@echo "Running workflow composition standard validation..."
	@./.github/tests/test-workflow-composition.sh

test-working-directory:
	@echo "Running working_directory threading validation..."
	@./.github/tests/test-working-directory.sh

test-supply-chain:
	@echo "Running supply-chain pinning validation..."
	@./.github/tests/test-supply-chain.sh

test-runner-cache-gating:
	@echo "Running self-hosted runner cache gating validation..."
	@./.github/tests/test-runner-cache-gating.sh

test-dependency-updates:
	@echo "Running dependency-update checker validation..."
	@./.github/tests/test-dependency-updates.sh

# Not part of `make test`: it talks to ~40 upstreams over the network, which a
# unit-test target must not do. The scheduled workflow runs it; this target is
# for running the same check by hand.
check-dependency-updates:
	@./global/scripts/tools/dependency-updates/run.sh

test-azure-step-names:
	@echo "Running Azure DevOps step-name uniqueness validation..."
	@./.github/tests/test-azure-step-names.sh

test-go-module-toolchain:
	@echo "Running Go module/builder toolchain agreement validation..."
	@./.github/tests/test-go-module-toolchain.sh

test: test-dependency-track test-go-module-toolchain test-go-script test-cyclonedx-main test-go-cache-trim test-go-tmpdir-modcache test-go-integration-scope test-go-tool-staleness test-lambda test-yaml-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-order-check test-var-catalog test-terraform-validate test-terraform-provider-mirror test-docker-multi-arch test-basic-checks test-gitignore test-dependency-check test-goreleaser-prepare test-release-version-extraction test-release-reconcile test-release-promotion test-deploy-providers test-memory-detection test-dart-pipeline test-javascript-pipeline test-terra-pipeline test-workflow-composition test-working-directory test-supply-chain test-runner-cache-gating test-azure-step-names test-dependency-updates test-containers-detect
	@echo "All tests completed successfully!"
