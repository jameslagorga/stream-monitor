IMAGE_NAME := gcr.io/lagorgeous-helping-hands/stream-monitor:latest
DOCKERFILE := Dockerfile
DOCKER_BUILD_PLATFORM := linux/amd64
RBAC_CHART := rbac.yaml
JOB_CHART := monitor-job.yaml

.PHONY: all build push apply delete apply-job delete-job

all: build push

build:
	cd .. && docker build --platform $(DOCKER_BUILD_PLATFORM) -t $(IMAGE_NAME) -f stream-monitor/$(DOCKERFILE) .

push:
	docker push $(IMAGE_NAME)

apply:
	kubectl apply -f $(RBAC_CHART)
	kubectl apply -f $(JOB_CHART)

delete:
	kubectl delete -f $(JOB_CHART) --ignore-not-found=true
	kubectl delete -f $(RBAC_CHART) --ignore-not-found=true
