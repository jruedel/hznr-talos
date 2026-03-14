include .env
export

SHELL = /bin/bash
.DEFAULT_GOAL := help

PACKER_DIR    = ./packer
TERRAFORM_DIR = ./terraform
TALOS_DIR     = ./talos
HELM_DIR      = ./helm
CLUSTER_NAME ?= talos
KUBECONFIG   ?= ./kubeconfig
KUBE_CTX     ?= admin@talos
ACME_EMAIL   ?=

IMAGE_ID ?= $(shell [ -f manifest.json ] && jq -r '.builds[-1].artifact_id' manifest.json)
export TF_VAR_image_id = $(IMAGE_ID)

# Terraform output helpers (only evaluated when targets need them)
LB_IP            = $(shell terraform -chdir=$(TERRAFORM_DIR) output -raw load_balancer_ipv4 2>/dev/null)
CLUSTER_ENDPOINT = $(shell terraform -chdir=$(TERRAFORM_DIR) output -raw cluster_endpoint 2>/dev/null)
CP_PUBLIC_IPS    = $(shell terraform -chdir=$(TERRAFORM_DIR) output -json controlplane_public_ips 2>/dev/null | jq -r '.[]')
WK_PUBLIC_IPS    = $(shell terraform -chdir=$(TERRAFORM_DIR) output -json worker_public_ips 2>/dev/null | jq -r '.[]')

.PHONY: help build-image init plan apply gen-config apply-config patch-config bootstrap get-kubeconfig destroy cluster deploy-hcloud-secret deploy-ccm deploy-ingress deploy-cert-manager deploy-services

help:
	@awk 'BEGIN {FS = ":.*##";} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-32s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Packer
build-image: ## Build Talos image via Packer
	packer init $(PACKER_DIR)
	@echo "Building image ..."
	packer build -var-file=$(PACKER_DIR)/instances.pkrvars.hcl $(PACKER_DIR)
	@echo "Image built: $$(jq -r '.builds[-1].artifact_id' manifest.json)"

##@ Terraform
init: ## Initialize Terraform providers and backend
	terraform -chdir=$(TERRAFORM_DIR) init

plan: ## Preview infrastructure changes
	terraform -chdir=$(TERRAFORM_DIR) plan

apply: ## Create or update infrastructure
	terraform -chdir=$(TERRAFORM_DIR) apply

destroy: ## Destroy all infrastructure
	terraform -chdir=$(TERRAFORM_DIR) destroy -var="image_id=$(or $(IMAGE_ID),0)"

##@ Talos Cluster
gen-config: ## Generate Talos machine configs via talosctl
	@if [ -z "$(CLUSTER_ENDPOINT)" ]; then \
		echo "Error: no cluster endpoint found. Run 'make apply' first."; \
		exit 1; \
	fi
	mkdir -p $(TALOS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--output-dir $(TALOS_DIR) \
		--with-docs=false \
		--with-examples=false \
		--config-patch @patches/cloud-provider.yaml \
		--config-patch @patches/flannel-private-network.yaml

apply-config: ## Apply Talos machine configs to all nodes
	@for ip in $(CP_PUBLIC_IPS); do \
		echo "Applying controlplane config to $$ip ..."; \
		talosctl apply-config --insecure \
			--nodes $$ip \
			--file $(TALOS_DIR)/controlplane.yaml; \
	done
	@for ip in $(WK_PUBLIC_IPS); do \
		echo "Applying worker config to $$ip ..."; \
		talosctl apply-config --insecure \
			--nodes $$ip \
			--file $(TALOS_DIR)/worker.yaml; \
	done

patch-config: ## Patch running nodes with files from patches/ dir
	@for ip in $(CP_PUBLIC_IPS) $(WK_PUBLIC_IPS); do \
		for patch in patches/*.yaml; do \
			echo "Patching $$ip with $$patch ..."; \
			talosctl --talosconfig=$(TALOS_DIR)/talosconfig \
				--nodes $$ip \
				patch machineconfig --patch @$$patch; \
		done; \
	done

bootstrap: ## Bootstrap the first control plane node
	talosctl bootstrap \
		--nodes $(firstword $(CP_PUBLIC_IPS)) \
		--endpoints $(firstword $(CP_PUBLIC_IPS)) \
		--talosconfig $(TALOS_DIR)/talosconfig

get-kubeconfig: ## Retrieve kubeconfig from the cluster
	talosctl kubeconfig ./kubeconfig \
		--nodes $(firstword $(CP_PUBLIC_IPS)) \
		--endpoints $(firstword $(CP_PUBLIC_IPS)) \
		--talosconfig $(TALOS_DIR)/talosconfig
	@echo "Kubeconfig saved to ./kubeconfig"

##@ Cluster Services
deploy-hcloud-secret: ## Create hcloud Secret for CCM
	@kubectl --kubeconfig=$(KUBECONFIG) --context=$(KUBE_CTX) -n kube-system create secret generic hcloud \
		--from-literal=token=$(HCLOUD_TOKEN) \
		--from-literal=network=$(CLUSTER_NAME)-network \
		--dry-run=client -o yaml | kubectl --kubeconfig=$(KUBECONFIG) --context=$(KUBE_CTX) apply -f -

deploy-ccm: ## Deploy Hetzner Cloud Controller Manager
	@helm repo add hcloud https://charts.hetzner.cloud 2>/dev/null || true
	@helm repo update hcloud
	helm upgrade --install hcloud-ccm hcloud/hcloud-cloud-controller-manager \
		--namespace kube-system \
		--kubeconfig $(KUBECONFIG) --kube-context=$(KUBE_CTX) \
		-f $(HELM_DIR)/hcloud-ccm-values.yaml

deploy-ingress: ## Deploy Nginx Ingress Controller
	@helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	@helm repo update ingress-nginx
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		--namespace ingress-nginx --create-namespace \
		--kubeconfig $(KUBECONFIG) --kube-context=$(KUBE_CTX) \
		-f $(HELM_DIR)/nginx-ingress-values.yaml

deploy-cert-manager: ## Deploy cert-manager with Let's Encrypt issuers
	@if [ -z "$(ACME_EMAIL)" ]; then \
		echo "Error: ACME_EMAIL is required. Set it in .env or pass via 'make deploy-cert-manager ACME_EMAIL=you@example.com'"; \
		exit 1; \
	fi
	@helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
	@helm repo update jetstack
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager --create-namespace \
		--kubeconfig $(KUBECONFIG) --kube-context=$(KUBE_CTX) \
		-f $(HELM_DIR)/cert-manager-values.yaml
	@echo "Waiting for cert-manager webhook to be ready ..."
	@kubectl --kubeconfig=$(KUBECONFIG) --context=$(KUBE_CTX) -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
	@echo "Waiting for webhook to accept connections ..."
	@for i in $$(seq 1 30); do \
		kubectl --kubeconfig=$(KUBECONFIG) --context=$(KUBE_CTX) -n cert-manager get secret cert-manager-webhook-ca >/dev/null 2>&1 && \
		kubectl --kubeconfig=$(KUBECONFIG) --context=$(KUBE_CTX) apply --dry-run=server -f k8s/cluster-issuer.yaml >/dev/null 2>&1 && \
		break; \
		echo "  attempt $$i/30 — webhook not ready yet"; \
		sleep 5; \
	done
	@sed 's/ACME_EMAIL_PLACEHOLDER/$(ACME_EMAIL)/g' k8s/cluster-issuer.yaml | \
		kubectl --kubeconfig=$(KUBECONFIG) --context=$(KUBE_CTX) apply -f -
	@echo "ClusterIssuers 'letsencrypt-staging' and 'letsencrypt-prod' created"

deploy-services: deploy-hcloud-secret deploy-ccm deploy-ingress deploy-cert-manager ## Deploy all cluster services (CCM + Ingress + TLS)

##@ Full Workflow
cluster: apply gen-config apply-config bootstrap get-kubeconfig deploy-services ## Provision infra, bootstrap, and deploy services end-to-end
