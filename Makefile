# Run from the repo root. `make help` lists targets.
# NOTE: recipe lines must be indented with TABS.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TF        := terraform -chdir=terraform/envs/dev
BOOTSTRAP := terraform -chdir=terraform/bootstrap
KARPENTER_VERSION ?= 1.15.2
# Region of the bootstrap state bucket
STATE_REGION      ?= eu-west-2

# Read lazily (=) from Terraform outputs, so they exist after `make apply`
out = $(shell $(TF) output -raw $(1) 2>/dev/null)
CLUSTER = $(call out,cluster_name)
REGION  = $(call out,region)

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

##---------------------------------------------------------- infrastructure
bootstrap: ## Once: state bucket + CI roles (make bootstrap GITHUB_ORG=you)
	$(BOOTSTRAP) init
	$(BOOTSTRAP) apply -var github_org=$(GITHUB_ORG)

init: ## Write backend.hcl from bootstrap outputs, then terraform init
	printf 'bucket = "%s"\nregion = "%s"\nkms_key_id = "%s"\n' \
	  "$$($(BOOTSTRAP) output -raw state_bucket)" "$(STATE_REGION)" \
	  "$$($(BOOTSTRAP) output -raw state_kms_key_arn)" > terraform/envs/dev/backend.hcl
	$(TF) init -reconfigure -backend-config=backend.hcl

plan: ## terraform plan
	$(TF) plan -out=tfplan

apply: ## Apply exactly the reviewed plan, then point kubectl at the cluster
	$(TF) apply tfplan
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

##---------------------------------------------------------- platform
platform: karpenter nodepools metrics-server kyverno monitoring ## Install all add-ons

karpenter: ## Karpenter controller (CRDs chart first so upgrades update CRDs)
	helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
	  --version $(KARPENTER_VERSION) -n kube-system
	helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
	  --version $(KARPENTER_VERSION) -n kube-system -f platform/karpenter/values.yaml \
	  --set settings.clusterName=$(CLUSTER) --set settings.interruptionQueue=$(call out,karpenter_queue) --wait

nodepools: ## EC2NodeClass + NodePools (values filled from Terraform outputs)
	CLUSTER_NAME=$(CLUSTER) NODE_ROLE=$(call out,karpenter_node_role) \
	  envsubst '$${CLUSTER_NAME} $${NODE_ROLE}' < platform/karpenter/nodepools.yaml | kubectl apply -f -

metrics-server: ## Needed by the HPA
	helm upgrade --install metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server/ \
	  --version 3.14.0 -n kube-system --set nodeSelector.node-role=system \
	  --set 'tolerations[0].key=CriticalAddonsOnly' --set 'tolerations[0].operator=Exists' --wait

kyverno: ## Kyverno + guardrail policies
	helm upgrade --install kyverno kyverno --repo https://kyverno.github.io/kyverno/ --version 3.9.2 \
	  -n kyverno --create-namespace -f platform/kyverno/values.yaml --wait
	kubectl apply -f platform/kyverno/policies.yaml

monitoring: ## Prometheus, Grafana (Karpenter dashboard), alerts, OpenCost
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || kubectl -n monitoring create secret generic \
	  grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$$(openssl rand -base64 24)"
	helm upgrade --install kube-prometheus-stack kube-prometheus-stack --version 93.3.0 -n monitoring \
	  --repo https://prometheus-community.github.io/helm-charts -f platform/monitoring/prometheus-values.yaml --wait --timeout 10m
	kubectl apply -f platform/monitoring/alerts.yaml
	helm upgrade --install opencost opencost --repo https://opencost.github.io/opencost-helm-chart --version 2.5.34 \
	  -n opencost --create-namespace -f platform/monitoring/opencost-values.yaml --wait

##---------------------------------------------------------- demo
app: ## Demo app + the inflate deployment
	kubectl apply -f k8s/demo-app.yaml -f k8s/inflate.yaml

inflate: ## 30 x 1 vCPU pods -> watch Karpenter add nodes
	kubectl -n demo scale deploy/inflate --replicas=30

deflate: ## 0 pods -> watch consolidation remove nodes
	kubectl -n demo scale deploy/inflate --replicas=0

watch: ## Live nodes with pool, Spot/on-demand, type, zone, arch
	watch -n5 kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type,topology.kubernetes.io/zone,kubernetes.io/arch

report: ## Live-priced cost of every node vs a static baseline
	scripts/cost-report.sh $(CLUSTER) $(REGION)

grafana: ## http://localhost:3000 (user admin)
	@echo "password: $$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

##---------------------------------------------------------- quality / teardown
lint: ## Same checks as CI (needs tflint, checkov, kyverno CLI, shellcheck)
	terraform fmt -recursive -check terraform
	tflint --init && tflint --chdir=terraform/envs/dev --config=$(CURDIR)/.tflint.hcl
	checkov -d . --quiet --compact --config-file .checkov.yaml
	kyverno apply platform/kyverno/policies.yaml --resource k8s/demo-app.yaml --resource k8s/inflate.yaml
	shellcheck scripts/*.sh

down: ## Karpenter nodes first, then terraform destroy, then orphan check
	scripts/teardown.sh

.PHONY: help bootstrap init plan apply platform karpenter nodepools metrics-server kyverno monitoring app inflate deflate watch report grafana lint down