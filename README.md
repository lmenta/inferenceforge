# InferenceForge

Production-grade LLM inference platform on Kubernetes. OpenAI-compatible API,
GPU-native, observable out of the box.

```
Client → Gateway (FastAPI) → Model Backend (Ollama | vLLM)
             │                        │
          Queue                    GPU node
        Rate limit              (g4dn.xlarge)
          Metrics               nvidia.com/gpu: 1
             │
         Prometheus → Grafana
```

## One-flag switch between CPU and GPU

```bash
# Local (CPU, free)
helm install inferenceforge ./chart -f chart/values-local.yaml

# AWS EKS (NVIDIA T4, spot ~$0.15/hr)
helm install inferenceforge ./chart -f chart/values-gpu.yaml
```

No code changes. The gateway is identical in both environments.

---

## Quick start (local, free)

**Prerequisites:** Docker, k3d, kubectl, helm, ollama

```bash
# 1. Start Ollama
ollama serve

# 2. Pull a model
ollama pull gemma3:1b

# 3. Install dependencies
python3 -m venv .venv && source .venv/bin/activate
pip install fastapi uvicorn httpx pydantic pydantic-settings prometheus-client

# 4. Start the gateway
PYTHONPATH=. MODEL_BACKEND_URL=http://localhost:11434 MODEL_NAME=gemma3:1b \
  uvicorn gateway.main:app --port 8082

# 5. Test it
curl -s -X POST http://localhost:8082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is Kubernetes?"}]}'

# 6. Check metrics
curl http://localhost:8082/metrics | grep inferenceforge_
```

## Full k3d cluster (local Kubernetes)

```bash
make local-up      # creates k3d cluster, builds image, deploys all services
make test          # health + inference check
make metrics       # print Prometheus metrics
make load-test     # run locust load test (20 users, 60s)
make local-down    # tear down
```

---

## Deploy on AWS (GPU)

```bash
# 1. Provision EKS + GPU node group
cd infra && terraform init && terraform apply

# 2. Configure kubectl
aws eks update-kubeconfig --name inferenceforge-dev --region eu-west-2

# 3. Install NVIDIA device plugin (exposes nvidia.com/gpu to K8s)
make nvidia-plugin

# 4. Deploy GPU stack
make eks-deploy
```

**Cost:** g4dn.xlarge spot ≈ $0.15/hr. GPU node group scales to **0** when idle.

---

## API

The gateway exposes an OpenAI-compatible interface.

```python
import openai

client = openai.OpenAI(base_url="http://localhost:8082/v1", api_key="not-needed")
response = client.chat.completions.create(
    model="gemma3:1b",
    messages=[{"role": "user", "content": "Hello"}]
)
```

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/chat/completions` | Inference (streaming + non-streaming) |
| GET | `/health` | Liveness probe |
| GET | `/ready` | Readiness probe (checks backend is reachable) |
| GET | `/metrics` | Prometheus metrics |
| GET | `/queue/status` | Real-time queue depth |

---

## Helm chart

```
chart/
  values.yaml          # defaults
  values-local.yaml    # CPU/local overrides
  values-gpu.yaml      # EKS GPU overrides
  templates/
    configmap.yaml
    gateway/deployment.yaml  service.yaml  hpa.yaml
    model/deployment.yaml    service.yaml
```

```bash
helm template test ./chart -f chart/values-local.yaml   # dry-run
helm lint chart/
helm install inferenceforge ./chart -f chart/values-local.yaml -n inferenceforge --create-namespace
```

---

## Kubernetes GPU scheduling

```yaml
tolerations:
  - key: nvidia.com/gpu       # schedule on GPU-tainted nodes
    operator: Exists
    effect: NoSchedule

nodeSelector:
  node.kubernetes.io/instance-type: g4dn.xlarge

resources:
  limits:
    nvidia.com/gpu: "1"       # request exactly one GPU
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for design rationale.

---

## Prometheus metrics

| Metric | Type | Description |
|--------|------|-------------|
| `inferenceforge_requests_total` | Counter | Requests by model and status |
| `inferenceforge_request_duration_seconds` | Histogram | Latency p50/p95/p99 |
| `inferenceforge_queue_depth` | Gauge | Waiting requests — HPA trigger |
| `inferenceforge_tokens_total` | Counter | Tokens generated |
| `inferenceforge_active_requests` | Gauge | Concurrent in-flight requests |
| `inferenceforge_backend_errors_total` | Counter | Backend failures by type |

Import `k8s/monitoring/grafana-dashboard.json` for the full dashboard.
