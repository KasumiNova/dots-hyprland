"""Upstream API client for ii AI backend."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict


class ProxyError(Exception):
    """Error from upstream API."""
    pass


def _env(name: str, default: str = "") -> str:
    v = os.environ.get(name)
    return default if v is None else v


def _json_bytes(obj: Any) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _join_url(base: str, path: str) -> str:
    b = (base or "").strip()
    if not b:
        return path
    if b.endswith("/"):
        b = b[:-1]
    if not path.startswith("/"):
        path = "/" + path
    return b + path


class UpstreamClient:
    """Client for proxying requests to upstream OpenAI-compatible API."""
    
    def __init__(self) -> None:
        self.base_url = _env("OPENAI_BASE_URL", "").strip() or "https://api.openai.com"
        self.api_key = _env("OPENAI_API_KEY", "").strip()

    def health(self) -> Dict[str, Any]:
        return {
            "upstream_base_url": self.base_url,
            "has_api_key": bool(self.api_key),
        }

    def request_chat_completions(self, body: Dict[str, Any]) -> urllib.response.addinfourl:
        """
        Make a chat completions request to upstream.
        Returns the raw response object for streaming.
        Raises ProxyError on failure.
        """
        url = _join_url(self.base_url, "/chat/completions")
        headers = {
            "Content-Type": "application/json",
            "Accept": "text/event-stream" if body.get("stream") else "application/json",
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        data = _json_bytes(body)
        req = urllib.request.Request(url=url, data=data, headers=headers, method="POST")
        try:
            return urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as e:
            try:
                err = e.read().decode("utf-8", errors="replace")
            except Exception:
                err = str(e)
            raise ProxyError(f"Upstream HTTPError {e.code}: {err}")
        except urllib.error.URLError as e:
            raise ProxyError(f"Upstream URLError: {e}")
