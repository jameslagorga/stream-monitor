IMAGE_NAME := gcr.io/lagorgeous-helping-hands/stream-monitor:latest
DOCKERFILE := Dockerfile
DOCKER_BUILD_PLATFORM := linux/amd64
DEPLOYMENT_CHART := deployment.yaml
RBAC_CHART := rbac.yaml

.PHONY: all build push apply delete

all: build push

build:
	cd .. && docker build --platform $(DOCKER_BUILD_PLATFORM) -t $(IMAGE_NAME) -f stream-monitor/$(DOCKERFILE) .

push:
	docker push $(IMAGE_NAME)

apply:
	kubectl apply -f $(RBAC_CHART)
	kubectl apply -f $(DEPLOYMENT_CHART)

delete:
	kubectl delete -f $(RBAC_CHART) --ignore-not-found=true
	kubectl delete -f $(DEPLOYMENT_CHART) --ignore-not-found=true
