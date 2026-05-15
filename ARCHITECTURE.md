# Architecture

## Why two separate services?

The gateway and the model backend are deliberately decoupled.

The **gateway** is stateless, horizontally scalable, and cheap to run. It handles
everything that doesn't require a GPU: rate limiting, request queuing, auth,
metrics, and API translation. You can run 10 replicas of it on tiny CPU nodes
for a few dollars a month.

The **model backend** is stateful (the model weights are loaded into GPU memory),
expensive to scale, and slow to start. Keeping it separate means you can scale
the gateway independently — handle a traffic spike by adding gateway replicas
without touching the GPU deployment.

This also makes swapping backends trivial. Change one ConfigMap value and
`MODEL_BACKEND_URL` — the gateway doesn't care whether it's talking to Ollama
on a MacBook or vLLM on a T4.

---

## Request flow

```
Client
  │
  ▼
Gateway (FastAPI)
  ├── Rate limiter: checks per-IP sliding window (in-memory, 60 req/min default)
  ├── Queue: asyncio.Semaphore — rejects at capacity, tracks depth in metric
  ├── Active counter: incremented on entry, decremented on exit
  │
  ▼
Model Backend
  ├── Ollama (local): POST /api/chat — returns Ollama JSON
  └── vLLM  (GPU):   POST /v1/chat/completions — returns OpenAI JSON
  │
  ▼
Gateway normalises response to OpenAI format
  │
  ▼
Prometheus metrics updated (latency, tokens, status)
  │
  ▼
Client receives OpenAI-compatible JSON
```

---

## Kubernetes GPU scheduling

On a GPU cluster (EKS with g4dn.xlarge nodes), three things must be true for
the model pod to land on a GPU node:

1. **NVIDIA Device Plugin DaemonSet** — runs on every GPU node, registers
   `nvidia.com/gpu` as a schedulable resource. Without it, K8s has no idea
   GPUs exist.

2. **Taint + Toleration** — GPU nodes are tainted `nvidia.com/gpu=true:NoSchedule`
   so only pods that explicitly tolerate that taint can land there. This prevents
   CPU workloads from consuming expensive GPU capacity.

3. **Resource request** — the model container must request `nvidia.com/gpu: 1`.
   K8s uses this to find a node with a free GPU slot. It also ensures the GPU
   is exclusively assigned (no sharing by default).

```yaml
# The three pieces in the model Deployment
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule

resources:
  limits:
    nvidia.com/gpu: "1"

nodeSelector:
  node.kubernetes.io/instance-type: g4dn.xlarge
```

---

## Autoscaling strategy

The HPA scales the **gateway** (not the model — GPU cold start is too slow for
reactive scaling). It uses two metrics simultaneously:

- **CPU utilisation** — standard K8s metric, triggers when gateways are compute-bound
- **`inferenceforge_queue_depth`** — custom Prometheus metric via prometheus-adapter

Scaling on queue depth is smarter than scaling on CPU alone. A slow model will
fill the queue before it stresses the gateway's CPU. The queue depth metric fires
earlier and more predictably.

The model backend uses a separate strategy: Karpenter watches for pods that can't
be scheduled (because no GPU node exists), provisions a new node, and the pod
lands within 2–3 minutes. It's slower than HPA but GPU nodes cost money — you
only want them when they're actually needed.

---

## Local vs GPU — the one-flag switch

The entire environment difference is encoded in `values-local.yaml` vs
`values-gpu.yaml`. No code changes, no branches.

| Setting | Local | GPU (EKS) |
|---------|-------|-----------|
| `model.backend` | ollama | vllm |
| `model.name` | gemma3:1b | mistralai/Mistral-7B |
| `model.backendPort` | 11434 | 8000 |
| `gpu.enabled` | false | true |
| `gateway.replicas` | 1 | 2 |
| `autoscaling.enabled` | false | true |

```bash
# Local
helm install inferenceforge ./chart -f chart/values-local.yaml

# GPU
helm install inferenceforge ./chart -f chart/values-gpu.yaml
```

---

## Metrics design

Every metric has a `model` label so you can compare performance across
different models on the same cluster without deploying separate dashboards.

| Metric | Type | Why |
|--------|------|-----|
| `inferenceforge_requests_total` | Counter | Request rate and error rate |
| `inferenceforge_request_duration_seconds` | Histogram | Latency SLOs — p50/p95/p99 |
| `inferenceforge_queue_depth` | Gauge | HPA trigger + capacity planning |
| `inferenceforge_tokens_total` | Counter | Throughput and cost estimation |
| `inferenceforge_active_requests` | Gauge | Concurrency — spot saturation early |
| `inferenceforge_backend_errors_total` | Counter | Backend health by error type |

The latency histogram uses non-uniform buckets (0.1s to 60s) because LLM
inference is slow and unpredictable. A bucket at 5s is more useful than one
at 1s for this workload.
