"""InferenceForge Gateway — OpenAI-compatible inference API with queue, rate limiting, and metrics."""
from __future__ import annotations

import time
import httpx
import asyncio
from contextlib import asynccontextmanager
from typing import AsyncIterator, Optional

from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

from gateway.config import settings
from gateway.metrics import (
    request_count, request_latency, tokens_generated,
    active_requests, backend_errors, queue_depth,
)
from gateway.queue import RequestQueue

# ── Shared state ─────────────────────────────────────────────────────────────

_queue: RequestQueue


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _queue
    _queue = RequestQueue(max_depth=settings.queue_max_depth)
    yield


app = FastAPI(
    title="InferenceForge Gateway",
    description="GPU-native LLM inference gateway for Kubernetes",
    version="1.0.0",
    lifespan=lifespan,
)

# ── Rate limiting ─────────────────────────────────────────────────────────────

_rate_buckets: dict[str, list[float]] = {}


def check_rate_limit(client_ip: str) -> bool:
    now = time.time()
    window = 60.0
    bucket = _rate_buckets.setdefault(client_ip, [])
    _rate_buckets[client_ip] = [t for t in bucket if now - t < window]
    if len(_rate_buckets[client_ip]) >= settings.rate_limit_per_minute:
        return False
    _rate_buckets[client_ip].append(now)
    return True


# ── Models ────────────────────────────────────────────────────────────────────

class Message(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    model: Optional[str] = None
    messages: list[Message]
    stream: bool = False
    max_tokens: Optional[int] = None
    temperature: Optional[float] = 0.7


# ── Backend adapters ──────────────────────────────────────────────────────────

def _build_ollama_payload(req: ChatRequest) -> dict:
    return {
        "model": req.model or settings.model_name,
        "messages": [m.model_dump() for m in req.messages],
        "stream": req.stream,
        "options": {
            "temperature": req.temperature or 0.7,
            **({"num_predict": req.max_tokens} if req.max_tokens else {}),
        },
    }


def _build_vllm_payload(req: ChatRequest) -> dict:
    return {
        "model": req.model or settings.model_name,
        "messages": [m.model_dump() for m in req.messages],
        "stream": req.stream,
        "max_tokens": req.max_tokens or 512,
        "temperature": req.temperature or 0.7,
    }


def _backend_url() -> str:
    if settings.backend_type == "vllm":
        return f"{settings.model_backend_url}/v1/chat/completions"
    return f"{settings.model_backend_url}/api/chat"


def _build_payload(req: ChatRequest) -> dict:
    return _build_vllm_payload(req) if settings.backend_type == "vllm" else _build_ollama_payload(req)


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "backend": settings.backend_type, "model": settings.model_name}


@app.get("/ready")
async def ready():
    """K8s readiness probe — checks backend is reachable."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            url = f"{settings.model_backend_url}/api/tags" if settings.backend_type == "ollama" else f"{settings.model_backend_url}/health"
            r = await client.get(url)
            if r.status_code == 200:
                return {"status": "ready"}
    except Exception:
        pass
    raise HTTPException(status_code=503, detail="Backend not ready")


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/queue/status")
def queue_status():
    return {
        "depth": _queue.depth,
        "max_depth": settings.queue_max_depth,
        "full": _queue.is_full(),
    }


@app.post("/v1/chat/completions")
async def chat_completions(req: ChatRequest, request: Request):
    client_ip = request.client.host if request.client else "unknown"

    # Rate limit check
    if not check_rate_limit(client_ip):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")

    # Queue capacity check
    if _queue.is_full():
        raise HTTPException(status_code=503, detail="Queue full — try again shortly")

    model_name = req.model or settings.model_name
    start = time.time()

    async with _queue:
        active_requests.inc()
        try:
            if req.stream:
                return StreamingResponse(
                    _stream_response(req, model_name, start),
                    media_type="text/event-stream",
                )
            else:
                return await _non_stream_response(req, model_name, start)
        finally:
            active_requests.dec()


async def _non_stream_response(req: ChatRequest, model_name: str, start: float):
    payload = _build_payload(req)
    try:
        async with httpx.AsyncClient(timeout=settings.request_timeout) as client:
            r = await client.post(_backend_url(), json=payload)
            r.raise_for_status()
            data = r.json()
    except httpx.HTTPError as e:
        backend_errors.labels(error_type=type(e).__name__).inc()
        request_count.labels(status="error", model=model_name).inc()
        raise HTTPException(status_code=502, detail=f"Backend error: {e}")

    elapsed = time.time() - start
    request_latency.labels(model=model_name).observe(elapsed)
    request_count.labels(status="success", model=model_name).inc()

    # Normalise Ollama response to OpenAI format
    if settings.backend_type == "ollama":
        content = data.get("message", {}).get("content", "")
        n_tokens = data.get("eval_count", 0)
        tokens_generated.labels(model=model_name).inc(n_tokens)
        return {
            "id": "chatcmpl-forge",
            "object": "chat.completion",
            "model": model_name,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
            "usage": {"completion_tokens": n_tokens},
        }

    tokens_generated.labels(model=model_name).inc(
        data.get("usage", {}).get("completion_tokens", 0)
    )
    return data


async def _stream_response(req: ChatRequest, model_name: str, start: float) -> AsyncIterator[str]:
    payload = _build_payload(req)
    token_count = 0
    try:
        async with httpx.AsyncClient(timeout=settings.request_timeout) as client:
            async with client.stream("POST", _backend_url(), json=payload) as r:
                r.raise_for_status()
                async for line in r.aiter_lines():
                    if line:
                        yield f"data: {line}\n\n"
                        token_count += 1
    except httpx.HTTPError as e:
        backend_errors.labels(error_type=type(e).__name__).inc()
    finally:
        elapsed = time.time() - start
        request_latency.labels(model=model_name).observe(elapsed)
        request_count.labels(status="success", model=model_name).inc()
        tokens_generated.labels(model=model_name).inc(token_count)
        yield "data: [DONE]\n\n"
