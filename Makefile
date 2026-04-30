TAG := latest
ROOT := global/containers
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

.PHONY: login setup-buildx build-and-push test-go-script test-lambda test-yaml-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-docker-multi-arch test

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

test-sonarqube:
	@echo "Running SonarQube auto-derivation validation..."
	@./.github/tests/test-sonarqube-auto-derive.sh

test-release-tag-idempotency:
	@echo "Running release tag idempotency validation..."
	@./.github/tests/test-release-tag-idempotency.sh

test-tftest-gen:
	@echo "Running tftest-gen generator validation..."
	@./.github/tests/test-tftest-gen.sh

test-docker-multi-arch:
	@echo "Running 40-delivery/docker multi-arch contract validation..."
	@./.github/tests/test-docker-multi-arch.sh

test: test-go-script test-lambda test-yaml-merge test-sonarqube test-release-tag-idempotency test-tftest-gen test-docker-multi-arch
	@echo "All tests completed successfully!"
