TAG := latest
ROOT := global/containers
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

build-and-push:
	docker login ${CONTAINER_REGISTRY}
	docker build -t "${CONTAINER_REGISTRY}/$(NAME):$(TAG)" -f "${ROOT}/$(NAME).$(TAG)/Dockerfile" "${ROOT}/$(NAME).$(TAG)"
	docker push "${CONTAINER_REGISTRY}/$(NAME):$(TAG)"

# Test targets
test-go-script:
	@echo "Running Go test script validation..."
	@./test-go-validation.sh

test: test-go-script
	@echo "All tests completed successfully!"
