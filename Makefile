TAG := latest
ROOT := global/containers
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

.PHONY: login setup-buildx build-and-push test-go-script test

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
	@./test-go-validation.sh

test: test-go-script
	@echo "All tests completed successfully!"
