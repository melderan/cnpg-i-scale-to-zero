.DEFAULT_GOAL := help

# Version detection
VERSION ?= $(shell git describe --tags --dirty 2>/dev/null || echo "dev")

# Local container builds use nerdctl in the k8s.io namespace so kubelet can see them
NERDCTL := nerdctl --namespace k8s.io

.PHONY: help
help: ## Show this help message
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: lint
lint: ## Lint source code
	@echo "Linting source code..."
	@go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.11.4
	@golangci-lint run

.PHONY: test
test: ## Run tests with coverage
	@go test -timeout 10m -race -cover -failfast ./...

.PHONY: build
build: ## Build plugin and sidecar binaries
	@echo "Building binaries with version: $(VERSION)"
	@CGO_ENABLED=0 go build -ldflags "-X github.com/melderan/cnpg-i-scale-to-zero/pkg/metadata.Version=$(VERSION)" -o bin/cnpg-i-scale-to-zero-plugin cmd/plugin/plugin.go
	@CGO_ENABLED=0 go build -ldflags "-X github.com/melderan/cnpg-i-scale-to-zero/pkg/metadata.Version=$(VERSION)" -o bin/cnpg-scale-to-zero-sidecar cmd/sidecar/sidecar.go

.PHONY: build-plugin-dev
build-plugin-dev: ## Build container image for the plugin (nerdctl, k8s.io namespace)
	@echo "Building plugin image with version: $(VERSION)"
	@$(NERDCTL) build -f Dockerfile.plugin --build-arg VERSION=$(VERSION) -t cnpg-i-scale-to-zero-plugin:dev .

.PHONY: build-sidecar-dev
build-sidecar-dev: ## Build container image for the sidecar (nerdctl, k8s.io namespace)
	@echo "Building sidecar image with version: $(VERSION)"
	@$(NERDCTL) build -f Dockerfile.sidecar --build-arg VERSION=$(VERSION) -t cnpg-scale-to-zero-sidecar:dev .

.PHONY: build-images-dev
build-images-dev: build-plugin-dev build-sidecar-dev ## Build both container images for local dev

.PHONY: manifest
manifest: ## Generate production Kubernetes manifest
	@echo "Generating Kubernetes manifest..."
	@kubectl kustomize kubernetes/ > manifest.yaml
	@echo "Manifest generated at manifest.yaml"

.PHONY: manifest-dev
manifest-dev: ## Generate development Kubernetes manifest with local images
	@echo "Generating development Kubernetes manifest..."
	@kubectl kustomize kubernetes/overlays/dev/ > manifest-dev.yaml
	@echo "Development manifest generated at manifest-dev.yaml"

.PHONY: deploy
deploy: manifest ## Deploy production manifest to the current cluster
	@echo "Deploying manifest to Kubernetes..."
	@kubectl apply -f manifest.yaml
	@echo "Waiting for deployment to be ready..."
	@kubectl wait --for=condition=available --timeout=300s deployment/scale-to-zero -n cnpg-system

.PHONY: deploy-dev
deploy-dev: build-images-dev manifest-dev ## Build images and deploy dev manifest to the current cluster
	@echo "Deploying development manifest to Kubernetes..."
	@kubectl apply -f manifest-dev.yaml
	@echo "Waiting for deployment to be ready..."
	@kubectl wait --for=condition=available --timeout=300s deployment/scale-to-zero -n cnpg-system

.PHONY: undeploy
undeploy: ## Remove the plugin from the current Kubernetes cluster
	@echo "Removing scale-to-zero plugin from Kubernetes..."
	@kubectl delete -f manifest.yaml --ignore-not-found=true

.PHONY: undeploy-dev
undeploy-dev: ## Remove the development plugin from the current Kubernetes cluster
	@echo "Removing scale-to-zero plugin from Kubernetes..."
	@kubectl delete -f manifest-dev.yaml --ignore-not-found=true

.PHONY: clean
clean: ## Clean build artifacts
	@echo "Cleaning build artifacts..."
	@rm -f bin/cnpg-i-scale-to-zero-plugin
	@rm -f bin/cnpg-scale-to-zero-sidecar
	@rm -f manifest-dev.yaml

.PHONY: test-local
test-local: ## Build, deploy, and create a test cluster in Rancher Desktop
	@./hack/test-local.sh

.PHONY: test-local-teardown
test-local-teardown: ## Remove test cluster and plugin from Rancher Desktop
	@./hack/test-local.sh teardown

.PHONY: all
all: lint test build build-images-dev ## Run all quality checks and build everything
