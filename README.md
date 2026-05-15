# InferenceForge

Production-grade LLM inference platform on Kubernetes. GPU-native, OpenAI-compatible, observable.

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │         Kubernetes Cluster           │
                    │                                      │
  Client ──────────►│  Gateway (FastAPI)                   │
  OpenAI API        │  ├── Rate limiting (60 req/min)      │
  compatible        │  ├── Request queue (depth: 100)      │
                    │  ├── /metrics (Prometheus)           │
                    │  └── HPA (scales on queue depth)     │
                    │            │                         │
                    │            ▼                         │
                    │  Model Backend                       │
                    │  ├── Local: Ollama (CPU)             │
                    │  └── AWS:   vLLM (NVIDIA T4 GPU)     │
                    │                                      │
                    │  Observability                       │
                    │  ├── Prometheus (metrics)            │
                    │  └── Grafana (dashboard)             │
                    └─────────────────────────────────────┘
```

## Quick start (local, free)

```bash
# Prerequisites: Docker, k3d, kubectl, helm, ollama
make local-up
```

This creates a k3d cluster, builds the gateway, deploys everything, and opens Grafana.

```bash
# Test inference
make test

# Watch metrics
make metrics

# Load test (requires locust)
make load-test
```

## Deploy on AWS GPU (EKS + g4dn.xlarge)

```bash
# 1. Provision infrastructure
cd infra && terraform init && terraform apply

# 2. Configure kubectl
aws eks update-kubeconfig --name inferenceforge-dev --region eu-west-2

# 3. Install NVIDIA device plugin
make nvidia-plugin

# 4. Deploy GPU stack
make eks-deploy
```

Cost: ~$0.15/hr on spot (g4dn.xlarge). GPU nodes scale to 0 when idle.

## GPU scheduling

The model deployment uses:
- **Tolerations** — pods schedule on GPU-tainted nodes
- **Node affinity** — prefer `g4dn.xlarge` (NVIDIA T4)
- **Resource limits** — `nvidia.com/gpu: 1` (managed by NVIDIA device plugin)
- **Karpenter** — autoscales GPU nodes based on pending pods

Switch between CPU/GPU with a single Helm flag:
```bash
# CPU (local)
helm install inferenceforge ./chart

# GPU (AWS)
helm install inferenceforge ./chart -f chart/values-gpu.yaml
```

## Metrics (Prometheus)

| Metric | Description |
|--------|-------------|
| `inferenceforge_requests_total` | Requests by status and model |
| `inferenceforge_request_duration_seconds` | Latency histogram (p50/p95/p99) |
| `inferenceforge_queue_depth` | Waiting requests in queue |
| `inferenceforge_tokens_total` | Tokens generated |
| `inferenceforge_active_requests` | Concurrent in-flight requests |
