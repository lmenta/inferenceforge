from __future__ import annotations
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    model_backend_url: str = "http://localhost:11434"   # Ollama local default
    model_name: str = "tinyllama"
    backend_type: str = "ollama"                         # ollama | vllm
    rate_limit_per_minute: int = 60
    queue_max_depth: int = 100
    request_timeout: int = 120

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
