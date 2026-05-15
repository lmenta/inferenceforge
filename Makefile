.PHONY: local-up local-down build deploy test load-test

CLUSTER   = inferenceforge-local
NAMESPACE = inferenceforge
IMAGE     = inferenceforge-gateway

# ── Local development ─────────────────────────────────────────────────────────

local-up: cluster-create build ollama-pull deploy-local monitoring open-grafana
	@echo "✓ InferenceForge running locally"
	@echo "  Gateway:  http://localhost:8080"
	@echo "  Grafana:  http://localhost:30300 (admin/admin)"

local-down:
	k3d cluster delete $(CLUSTER)

cluster-create:
	@k3d cluster list | grep -q $(CLUSTER) || \
	k3d cluster create $(CLUSTER) \
	  --port "8080:80@loadbalancer" \
	  --port "30300:30300@server:0" \
	  --agents 2

build:
	docker build -t $(IMAGE):latest -f gateway/Dockerfile .
	k3d image import $(IMAGE):latest -c $(CLUSTER)

ollama-pull:
	@echo "Pulling TinyLlama model via Ollama..."
	ollama pull tinyllama 2>/dev/null || true

deploy-local:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n $(NAMESPACE) -f k8s/model/configmap.yaml
	kubectl apply -n $(NAMESPACE) -f k8s/model/deployment.yaml
	kubectl apply -n $(NAMESPACE) -f k8s/model/service.yaml
	kubectl apply -n $(NAMESPACE) -f k8s/gateway/deployment.yaml
	kubectl apply -n $(NAMESPACE) -f k8s/gateway/service.yaml
	kubectl apply -n $(NAMESPACE) -f k8s/gateway/hpa.yaml
	@echo "Waiting for pods..."
	kubectl rollout status deployment/inferenceforge-gateway -n $(NAMESPACE) --timeout=120s

monitoring:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
	  --namespace monitoring --create-namespace \
	  --set grafana.service.type=NodePort \
	  --set grafana.service.nodePort=30300 \
	  --set grafana.adminPassword=admin \
	  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
	  --wait --timeout 5m
	kubectl create configmap inferenceforge-grafana-dashboard \
	  --from-file=inferenceforge.json=k8s/monitoring/grafana-dashboard.json \
	  --namespace monitoring --dry-run=client -o yaml \
	  | kubectl label -f - --dry-run=client -o yaml --local grafana_dashboard=1 \
	  | kubectl apply -f -

open-grafana:
	@echo "Opening Grafana at http://localhost:30300 (admin/admin)"
	open http://localhost:30300 || true

# ── Testing ────────────────────────────────────────────────────────────────────

test:
	@echo "Testing gateway health..."
	curl -s http://localhost:8080/health | python3 -m json.tool
	@echo "\nTesting chat endpoint..."
	curl -s -X POST http://localhost:8080/v1/chat/completions \
	  -H "Content-Type: application/json" \
	  -d '{"messages":[{"role":"user","content":"Say hello in one sentence."}]}' \
	  | python3 -m json.tool

metrics:
	curl -s http://localhost:8080/metrics | grep inferenceforge

load-test:
	@command -v locust >/dev/null || pip install locust -q
	locust -f tests/locustfile.py --host http://localhost:8080 \
	  --users 20 --spawn-rate 2 --run-time 60s --headless

port-forward:
	kubectl port-forward svc/inferenceforge-gateway 8080:80 -n $(NAMESPACE) &

logs:
	kubectl logs -l app=inferenceforge-gateway -n $(NAMESPACE) --follow

# ── AWS GPU deploy (requires AWS account + kubectl context) ───────────────────

eks-deploy:
	helm upgrade --install inferenceforge ./chart \
	  --namespace $(NAMESPACE) --create-namespace \
	  -f chart/values.yaml \
	  -f chart/values-gpu.yaml

nvidia-plugin:
	kubectl apply -f k8s/nvidia-device-plugin.yaml
