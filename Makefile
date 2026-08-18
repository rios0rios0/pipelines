TAG := latest
ROOT := global/containers
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

.PHONY: login setup-buildx build-and-push test-go-script test-cyclonedx-main test-go-cache-trim test-go-tmpdir-modcache test-go-integration-scope test-lambda test-yaml-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-order-check test-var-catalog test-terraform-validate test-terraform-provider-mirror test-docker-multi-arch test-basic-checks test-dependency-check test-goreleaser-prepare test-release-version-extraction test-release-reconcile test-deploy-providers test-memory-detection test-dart-pipeline test-workflow-composition test-supply-chain test-azure-step-names test

login:
	docker login $(CONTAINER_REGISTRY)

setup-buildx:
	docker buildx create --use

build-and-push:
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		--tag "$(CONTAINER_REGISTRY)/$(NAME):$(TAG)" \
		--file "$(ROOT)/$(NAME).$(TAG)/Dockerfile" \
		--push "$(ROOT)/$(NAME).$(TAG)"

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

test-basic-checks:
	@echo "Running basic-checks changelog validation..."
	@./.github/tests/test-basic-checks.sh

test-dependency-check:
	@echo "Running OWASP Dependency-Check NVD cache/API-key validation..."
	@./.github/tests/test-dependency-check.sh

test-goreleaser-prepare:
	@echo "Running GoReleaser main package detection validation..."
	@./.github/tests/test-goreleaser-prepare.sh

test-release-version-extraction:
	@echo "Running release version extraction validation..."
	@./.github/tests/test-release-version-extraction.sh

test-release-reconcile:
	@echo "Running release reconciliation validation..."
	@./.github/tests/test-release-reconcile.sh

test-deploy-providers:
	@echo "Running MVP hosting deployment provider validation..."
	@./.github/tests/test-deploy-providers.sh

test-memory-detection:
	@echo "Running memory ceiling detection validation..."
	@./.github/tests/test-memory-detection.sh

test-dart-pipeline:
	@echo "Running Dart/Flutter pipeline validation..."
	@./.github/tests/test-dart-pipeline.sh

test-workflow-composition:
	@echo "Running workflow composition standard validation..."
	@./.github/tests/test-workflow-composition.sh

test-supply-chain:
	@echo "Running supply-chain pinning validation..."
	@./.github/tests/test-supply-chain.sh

test-azure-step-names:
	@echo "Running Azure DevOps step-name uniqueness validation..."
	@./.github/tests/test-azure-step-names.sh

test: test-go-script test-cyclonedx-main test-go-cache-trim test-go-tmpdir-modcache test-go-integration-scope test-lambda test-yaml-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-order-check test-var-catalog test-terraform-validate test-terraform-provider-mirror test-docker-multi-arch test-basic-checks test-dependency-check test-goreleaser-prepare test-release-version-extraction test-release-reconcile test-deploy-providers test-memory-detection test-dart-pipeline test-workflow-composition test-supply-chain test-azure-step-names
	@echo "All tests completed successfully!"
