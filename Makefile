IMAGE_NAME := gcr.io/lagorgeous-helping-hands/stream-monitor:latest
DOCKERFILE := Dockerfile
DOCKER_BUILD_PLATFORM := linux/amd64
RBAC_CHART := rbac.yaml
CRONJOB_CHART := cronjob.yaml

.PHONY: all build push apply delete apply-cronjob delete-cronjob

all: build push

build:
	cd .. && docker build --platform $(DOCKER_BUILD_PLATFORM) -t $(IMAGE_NAME) -f stream-monitor/$(DOCKERFILE) .

push:
	docker push $(IMAGE_NAME)

apply: apply-cronjob

delete: delete-cronjob

apply-cronjob:
	kubectl apply -f $(RBAC_CHART)
	kubectl apply -f $(CRONJOB_CHART)

delete-cronjob:
	kubectl delete -f $(CRONJOB_CHART) --ignore-not-found=true
	kubectl delete -f $(RBAC_CHART) --ignore-not-found=true
