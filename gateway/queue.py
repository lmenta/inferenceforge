"""Async request queue with configurable depth."""
from __future__ import annotations
import asyncio
from gateway.metrics import queue_depth


class RequestQueue:
    def __init__(self, max_depth: int = 100):
        self._sem = asyncio.Semaphore(max_depth)
        self._max = max_depth
        self._active = 0

    async def __aenter__(self):
        await self._sem.acquire()
        self._active += 1
        queue_depth.set(self._max - self._sem._value)
        return self

    async def __aexit__(self, *_):
        self._active -= 1
        self._sem.release()
        queue_depth.set(self._max - self._sem._value)

    @property
    def depth(self) -> int:
        return self._max - self._sem._value

    def is_full(self) -> bool:
        return self._sem._value == 0
