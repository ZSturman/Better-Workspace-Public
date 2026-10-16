"""Small, local OpenAI-compatible client used by optional consumers.

This module deliberately knows nothing about watcher events or SQLite.  A
caller can record failures, retain deterministic output, and continue its own
work when the local server is unavailable.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class LMStudioError(RuntimeError):
    """A bounded, user-readable local-server failure."""


@dataclass(frozen=True)
class LMStudioHealth:
    ok: bool
    models: list[str]
    error: str | None = None


class LMStudioClient:
    def __init__(self, base_url: str = "http://localhost:1234/v1", timeout_seconds: float = 20.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = max(1.0, float(timeout_seconds))

    def models(self) -> list[str]:
        result = self._request("/models")
        data = result.get("data")
        if not isinstance(data, list):
            raise LMStudioError("LM Studio /models response has no model list")
        return [str(item["id"]) for item in data if isinstance(item, dict) and item.get("id")]

    def health(self) -> LMStudioHealth:
        try:
            return LMStudioHealth(True, self.models())
        except LMStudioError as exc:
            return LMStudioHealth(False, [], str(exc))

    def chat_completion(self, messages: list[dict[str, str]], *, model: str = "", max_tokens: int = 180) -> tuple[str, str | None]:
        body: dict[str, Any] = {
            "temperature": 0, "max_tokens": max_tokens, "stream": False,
            "messages": messages,
            # A reasoning-capable model otherwise spends the whole max_tokens
            # budget on hidden chain-of-thought and returns empty visible
            # content (observed live with qwen3.5-9b via LM Studio). Servers
            # that don't recognize this field ignore it.
            "reasoning_effort": "none",
        }
        # LM Studio can select its loaded/default model.  Omitting model is
        # intentional when configuration leaves it blank.
        if model:
            body["model"] = model
        result = self._request("/chat/completions", body)
        choices = result.get("choices")
        if not isinstance(choices, list) or not choices:
            raise LMStudioError("LM Studio returned no chat choices")
        message = choices[0].get("message") if isinstance(choices[0], dict) else None
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, str) or not content.strip():
            raise LMStudioError("LM Studio returned an empty chat response")
        used_model = result.get("model")
        return content.strip()[:900], str(used_model) if used_model else (model or None)

    def embeddings(self, inputs: list[str], *, model: str = "") -> tuple[list[list[float]], str | None]:
        if not inputs:
            return [], model or None
        body: dict[str, Any] = {"input": inputs}
        if model:
            body["model"] = model
        result = self._request("/embeddings", body)
        data = result.get("data")
        if not isinstance(data, list) or len(data) != len(inputs):
            raise LMStudioError("LM Studio returned an invalid embeddings response")
        vectors: list[list[float]] = []
        for item in data:
            vector = item.get("embedding") if isinstance(item, dict) else None
            if not isinstance(vector, list) or not all(isinstance(x, (int, float)) for x in vector):
                raise LMStudioError("LM Studio returned an invalid embedding vector")
            vectors.append([float(x) for x in vector])
        used_model = result.get("model")
        return vectors, str(used_model) if used_model else (model or None)

    def _request(self, suffix: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        data = json.dumps(body).encode() if body is not None else None
        request = Request(
            f"{self.base_url}{suffix}", data=data,
            headers={"Content-Type": "application/json"} if data else {},
            method="POST" if data else "GET",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            raise LMStudioError(f"LM Studio request to {suffix} failed: {exc}") from exc
        if not isinstance(payload, dict):
            raise LMStudioError(f"LM Studio {suffix} response was not an object")
        return payload
