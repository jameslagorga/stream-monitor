IMAGE_NAME := gcr.io/lagorgeous-helping-hands/stream-monitor:latest
DOCKERFILE := Dockerfile
DOCKER_BUILD_PLATFORM := linux/amd64
JOB_CHART := job.yaml
RBAC_CHART := rbac.yaml

.PHONY: all build push apply run delete

all: build push

build:
	cd .. && docker build --platform $(DOCKER_BUILD_PLATFORM) -t $(IMAGE_NAME) -f stream-monitor/$(DOCKERFILE) .

push:
	docker push $(IMAGE_NAME)

apply:
	kubectl apply -f $(RBAC_CHART)

run:
	kubectl delete job stream-monitor-job --ignore-not-found=true
	kubectl apply -f $(JOB_CHART)

delete:
	kubectl delete -f $(JOB_CHART) --ignore-not-found=true
	kubectl delete -f $(RBAC_CHART) --ignore-not-found=true
