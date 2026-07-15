TAG := latest
ROOT := global/containers
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

.PHONY: login setup-buildx build-and-push test-go-script test-lambda test-yaml-merge test-trivy-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-order-check test-docker-multi-arch test-basic-checks test-dependency-check test-release-version-extraction test-release-reconcile test

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

test-lambda:
	@echo "Running Lambda template validation..."
	@./.github/tests/test-lambda-templates.sh

test-yaml-merge:
	@echo "Running YAML merge validation..."
	@./.github/tests/test-yaml-merge.sh

test-trivy-merge:
	@echo "Running Trivy ignore merge validation..."
	@./.github/tests/test-trivy-merge.sh

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

test: test-go-script test-lambda test-yaml-merge test-trivy-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-order-check test-docker-multi-arch test-basic-checks test-dependency-check test-goreleaser-prepare test-release-version-extraction test-release-reconcile
	@echo "All tests completed successfully!"
