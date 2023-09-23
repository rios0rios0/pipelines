TAG := latest
CONTAINER_REGISTRY = ghcr.io/rios0rios0/pipelines

build-and-push:
	docker login ${CONTAINER_REGISTRY}
	docker build -t "${CONTAINER_REGISTRY}/$(NAME):$(TAG)" -f "shared/containers/$(NAME)$(TAG).Dockerfile" .
	docker push "${CONTAINER_REGISTRY}/$(NAME):$(TAG)"
