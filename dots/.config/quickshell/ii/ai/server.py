#!/usr/bin/env python3
"""ii AI backend v2

Stdlib-only local proxy with chat history persistence and tool execution.

Endpoints:
- GET  /v1/health
- POST /v1/chat/completions   (stream + non-stream, proxied to upstream with tool handling)
- GET  /v1/chats              (list all chats)
- GET  /v1/chats/<id>         (get chat by id)
- POST /v1/chats              (create new chat)
- PUT  /v1/chats/<id>         (update chat)
- DELETE /v1/chats/<id>       (delete chat)
- GET  /v1/messages/<chat_id> (get messages for chat)
- POST /v1/messages/<chat_id> (add message to chat)
- DELETE /v1/messages/<msg_id> (delete message)
- POST /v1/tools              (execute a tool directly)
- GET  /v1/tools/definitions  (get tool definitions)

Upstream is configured via env:
- OPENAI_BASE_URL   e.g. https://api.deepseek.com (no /v1)
- OPENAI_API_KEY

This server is managed by systemd, NOT Quickshell.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional

# Allow running as both module and script
if __name__ == "__main__":
    # Running as script - add parent directory to path for imports
    _script_dir = Path(__file__).parent
    sys.path.insert(0, str(_script_dir.parent))
    from ai.tools import execute_tool, get_tool_definitions
    from ai.upstream import UpstreamClient, ProxyError
    from ai.streaming import StreamHandler
else:
    # Running as module - use relative imports
    from .tools import execute_tool, get_tool_definitions
    from .upstream import UpstreamClient, ProxyError
    from .streaming import StreamHandler

# ─────────────────────────────────────────────────────────────────────────────
# Database
# ─────────────────────────────────────────────────────────────────────────────

DB_PATH = Path(os.environ.get("II_AI_DB_PATH", "")).expanduser()
if not DB_PATH or DB_PATH == Path(""):
    DB_PATH = Path.home() / ".local" / "state" / "quickshell" / "ai" / "chats.db"

DB_PATH.parent.mkdir(parents=True, exist_ok=True)

_db_lock = threading.Lock()


def _get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def _init_db(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS chats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
            updated_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
        );
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            raw_content TEXT NOT NULL DEFAULT '',
            model TEXT DEFAULT '',
            thinking INTEGER NOT NULL DEFAULT 0,
            done INTEGER NOT NULL DEFAULT 1,
            function_name TEXT DEFAULT '',
            function_call TEXT DEFAULT '',
            function_response TEXT DEFAULT '',
            tool_calls TEXT DEFAULT '[]',
            usage_prompt_tokens INTEGER,
            usage_completion_tokens INTEGER,
            usage_total_tokens INTEGER,
            usage_estimated INTEGER NOT NULL DEFAULT 0,
            annotations TEXT DEFAULT '[]',
            annotation_sources TEXT DEFAULT '[]',
            created_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
        );
        CREATE INDEX IF NOT EXISTS idx_messages_chat_id ON messages(chat_id);
    """)

    # Lightweight schema migration for existing installs.
    # SQLite doesn't support IF NOT EXISTS on ADD COLUMN.
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(messages)").fetchall()}
    if "tool_calls" not in cols:
        conn.execute("ALTER TABLE messages ADD COLUMN tool_calls TEXT DEFAULT '[]'")

    # Token usage persistence (per request / per assistant message)
    if "usage_prompt_tokens" not in cols:
        conn.execute("ALTER TABLE messages ADD COLUMN usage_prompt_tokens INTEGER")
    if "usage_completion_tokens" not in cols:
        conn.execute("ALTER TABLE messages ADD COLUMN usage_completion_tokens INTEGER")
    if "usage_total_tokens" not in cols:
        conn.execute("ALTER TABLE messages ADD COLUMN usage_total_tokens INTEGER")
    if "usage_estimated" not in cols:
        conn.execute("ALTER TABLE messages ADD COLUMN usage_estimated INTEGER NOT NULL DEFAULT 0")

    conn.commit()


_db_conn: Optional[sqlite3.Connection] = None


def get_db() -> sqlite3.Connection:
    global _db_conn
    if _db_conn is None:
        _db_conn = _get_db()
        _init_db(_db_conn)
    return _db_conn


# ─────────────────────────────────────────────────────────────────────────────
# Chat/Message CRUD
# ─────────────────────────────────────────────────────────────────────────────


def list_chats() -> List[Dict[str, Any]]:
    with _db_lock:
        cur = get_db().execute("SELECT * FROM chats ORDER BY updated_at DESC")
        return [dict(r) for r in cur.fetchall()]


def get_chat(chat_id: int) -> Optional[Dict[str, Any]]:
    with _db_lock:
        cur = get_db().execute("SELECT * FROM chats WHERE id = ?", (chat_id,))
        row = cur.fetchone()
        return dict(row) if row else None


def create_chat(name: str = "") -> Dict[str, Any]:
    with _db_lock:
        conn = get_db()
        cur = conn.execute("INSERT INTO chats (name) VALUES (?)", (name,))
        conn.commit()
        chat_id = cur.lastrowid
    return get_chat(chat_id) or {"id": chat_id, "name": name}


def update_chat(chat_id: int, name: str) -> Optional[Dict[str, Any]]:
    with _db_lock:
        conn = get_db()
        conn.execute(
            "UPDATE chats SET name = ?, updated_at = strftime('%s', 'now') WHERE id = ?",
            (name, chat_id)
        )
        conn.commit()
    return get_chat(chat_id)


def delete_chat(chat_id: int) -> bool:
    with _db_lock:
        conn = get_db()
        cur = conn.execute("DELETE FROM chats WHERE id = ?", (chat_id,))
        conn.commit()
        return cur.rowcount > 0


def clear_chat(chat_id: int) -> bool:
    with _db_lock:
        conn = get_db()
        conn.execute("DELETE FROM messages WHERE chat_id = ?", (chat_id,))
        conn.commit()
        return True


def get_messages(chat_id: int) -> List[Dict[str, Any]]:
    with _db_lock:
        cur = get_db().execute(
            "SELECT * FROM messages WHERE chat_id = ? ORDER BY id ASC",
            (chat_id,)
        )
        rows = cur.fetchall()
    result = []
    for r in rows:
        msg = dict(r)
        for field in ("annotations", "annotation_sources", "function_call", "tool_calls"):
            if msg.get(field):
                try:
                    msg[field] = json.loads(msg[field])
                except Exception:
                    pass
        msg["thinking"] = bool(msg.get("thinking"))
        msg["done"] = bool(msg.get("done", True))
        result.append(msg)
    return result


def add_message(chat_id: int, msg: Dict[str, Any]) -> Dict[str, Any]:
    role = msg.get("role", "user")
    content = msg.get("content", "")
    raw_content = msg.get("rawContent") or msg.get("raw_content") or content
    model = msg.get("model", "")
    thinking = 1 if msg.get("thinking") else 0
    done = 1 if msg.get("done", True) else 0
    function_name = msg.get("functionName") or msg.get("function_name", "")
    function_call = msg.get("functionCall") or msg.get("function_call")
    function_response = msg.get("functionResponse") or msg.get("function_response", "")
    tool_calls = msg.get("toolCalls") or msg.get("tool_calls", [])
    annotations = msg.get("annotations", [])
    annotation_sources = msg.get("annotationSources") or msg.get("annotation_sources", [])

    # Optional token usage (OpenAI-style usage object)
    usage = msg.get("usage") or {}
    if not isinstance(usage, dict):
        usage = {}
    usage_prompt_tokens = msg.get("usage_prompt_tokens")
    usage_completion_tokens = msg.get("usage_completion_tokens")
    usage_total_tokens = msg.get("usage_total_tokens")
    if usage_prompt_tokens is None:
        usage_prompt_tokens = usage.get("prompt_tokens")
    if usage_completion_tokens is None:
        usage_completion_tokens = usage.get("completion_tokens")
    if usage_total_tokens is None:
        usage_total_tokens = usage.get("total_tokens")
    usage_estimated = msg.get("usage_estimated")
    if usage_estimated is None:
        usage_estimated = usage.get("estimated", False)
    usage_estimated_i = 1 if bool(usage_estimated) else 0

    def _to_int_or_none(v: Any) -> Optional[int]:
        try:
            if v is None:
                return None
            iv = int(v)
            return iv if iv >= 0 else None
        except Exception:
            return None

    usage_prompt_tokens = _to_int_or_none(usage_prompt_tokens)
    usage_completion_tokens = _to_int_or_none(usage_completion_tokens)
    usage_total_tokens = _to_int_or_none(usage_total_tokens)

    if isinstance(function_call, dict):
        function_call = json.dumps(function_call, ensure_ascii=False)
    elif function_call is None:
        function_call = ""
    if isinstance(annotations, list):
        annotations = json.dumps(annotations, ensure_ascii=False)
    if isinstance(annotation_sources, list):
        annotation_sources = json.dumps(annotation_sources, ensure_ascii=False)
    if isinstance(tool_calls, (list, dict)):
        tool_calls = json.dumps(tool_calls, ensure_ascii=False)
    elif tool_calls is None:
        tool_calls = "[]"

    with _db_lock:
        conn = get_db()
        cur = conn.execute(
            """INSERT INTO messages 
                    (chat_id, role, content, raw_content, model, thinking, done, 
                     function_name, function_call, function_response, tool_calls,
                     usage_prompt_tokens, usage_completion_tokens, usage_total_tokens, usage_estimated,
                     annotations, annotation_sources)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (chat_id, role, content, raw_content, model, thinking, done,
                 function_name, function_call, function_response, tool_calls,
                 usage_prompt_tokens, usage_completion_tokens, usage_total_tokens, usage_estimated_i,
                 annotations, annotation_sources)
        )
        conn.execute(
            "UPDATE chats SET updated_at = strftime('%s', 'now') WHERE id = ?",
            (chat_id,)
        )
        conn.commit()
        msg_id = cur.lastrowid

    return {
        "id": msg_id,
        "chat_id": chat_id,
        "role": role,
        "content": content,
        "usage_prompt_tokens": usage_prompt_tokens,
        "usage_completion_tokens": usage_completion_tokens,
        "usage_total_tokens": usage_total_tokens,
        "usage_estimated": bool(usage_estimated_i),
    }


def update_message(msg_id: int, updates: Dict[str, Any]) -> bool:
    fields = []
    values = []
    for k, v in updates.items():
        key = "raw_content" if k == "rawContent" else k
        if key in ("content", "raw_content"):
            fields.append(f"{key} = ?")
            values.append(v)
        elif key == "done":
            fields.append("done = ?")
            values.append(1 if v else 0)
        elif key == "thinking":
            fields.append("thinking = ?")
            values.append(1 if v else 0)
    if not fields:
        return False
    values.append(msg_id)
    with _db_lock:
        conn = get_db()
        conn.execute(f"UPDATE messages SET {', '.join(fields)} WHERE id = ?", values)
        conn.commit()
    return True


def delete_message(msg_id: int) -> bool:
    with _db_lock:
        conn = get_db()
        cur = conn.execute("DELETE FROM messages WHERE id = ?", (msg_id,))
        conn.commit()
        return cur.rowcount > 0


def get_or_create_current_chat() -> Dict[str, Any]:
    chats = list_chats()
    if chats:
        return chats[0]
    return create_chat("Default")


# ─────────────────────────────────────────────────────────────────────────────
# Upstream (OpenAI proxy)
# ─────────────────────────────────────────────────────────────────────────────


def _env(name: str, default: str = "") -> str:
    v = os.environ.get(name)
    return default if v is None else v


def _json_bytes(obj: Any) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _read_json(handler: BaseHTTPRequestHandler) -> Any:
    length = int(handler.headers.get("Content-Length", "0") or "0")
    raw = handler.rfile.read(length) if length > 0 else b"{}"
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        raise ValueError("Invalid JSON")


def _join_url(base: str, path: str) -> str:
    b = (base or "").strip()
    if not b:
        return path
    if b.endswith("/"):
        b = b[:-1]
    if not path.startswith("/"):
        path = "/" + path
    return b + path


# ─────────────────────────────────────────────────────────────────────────────
# HTTP Handler
# ─────────────────────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    server_version = "ii-ai-backend/0.2"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def _send_json(self, code: int, obj: Any) -> None:
        payload = _json_bytes(obj)
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_error_json(self, code: int, message: str) -> None:
        self._send_json(code, {"error": {"message": message}})

    def _parse_path(self) -> tuple:
        path = self.path.rstrip("/")
        # Handle /v1/chat/completions specially
        if path == "/v1/chat/completions":
            return "chat/completions", None
        m = re.match(r"^/v1/(\w+)/(\d+)$", path)
        if m:
            return m.group(1), int(m.group(2))
        m = re.match(r"^/v1/(\w+)$", path)
        if m:
            return m.group(1), None
        return "", None

    def do_GET(self) -> None:
        resource, rid = self._parse_path()

        if resource == "health":
            client = self.server.upstream
            self._send_json(200, client.health())
            return

        if resource == "chats":
            if rid is not None:
                chat = get_chat(rid)
                if chat:
                    self._send_json(200, chat)
                else:
                    self._send_error_json(404, "Chat not found")
            else:
                self._send_json(200, list_chats())
            return

        if resource == "messages":
            if rid is not None:
                self._send_json(200, get_messages(rid))
            else:
                self._send_error_json(400, "Chat ID required")
            return

        if resource == "current":
            chat = get_or_create_current_chat()
            chat["messages"] = get_messages(chat["id"])
            self._send_json(200, chat)
            return

        if resource == "tools":
            # GET /v1/tools returns tool definitions
            self._send_json(200, {"tools": get_tool_definitions()})
            return

        self._send_error_json(404, "Not found")

    def do_POST(self) -> None:
        resource, rid = self._parse_path()

        if resource == "chat/completions":
            self._handle_chat_completions()
            return

        try:
            body = _read_json(self)
            if not isinstance(body, dict):
                body = {}
        except ValueError as e:
            self._send_error_json(400, str(e))
            return

        if resource == "chats":
            if rid is None:
                name = body.get("name", "")
                chat = create_chat(name)
                self._send_json(201, chat)
            else:
                self._send_error_json(400, "Use PUT to update")
            return

        if resource == "messages":
            if rid is not None:
                msg = add_message(rid, body)
                self._send_json(201, msg)
            else:
                self._send_error_json(400, "Chat ID required")
            return

        if resource == "clear":
            if rid is not None:
                clear_chat(rid)
                self._send_json(200, {"ok": True})
            else:
                self._send_error_json(400, "Chat ID required")
            return

        if resource == "tools":
            # Execute a tool: POST /v1/tools with body {"name": "...", "args": {...}}
            tool_name = body.get("name", "")
            tool_args = body.get("args", {})
            if not tool_name:
                self._send_error_json(400, "Tool name required")
                return
            result = execute_tool(tool_name, tool_args)
            self._send_json(200, result)
            return

        self._send_error_json(404, "Not found")

    def do_PUT(self) -> None:
        resource, rid = self._parse_path()

        try:
            body = _read_json(self)
            if not isinstance(body, dict):
                body = {}
        except ValueError as e:
            self._send_error_json(400, str(e))
            return

        if resource == "chats" and rid is not None:
            name = body.get("name", "")
            chat = update_chat(rid, name)
            if chat:
                self._send_json(200, chat)
            else:
                self._send_error_json(404, "Chat not found")
            return

        if resource == "messages" and rid is not None:
            if update_message(rid, body):
                self._send_json(200, {"ok": True})
            else:
                self._send_error_json(404, "Message not found")
            return

        self._send_error_json(404, "Not found")

    def do_DELETE(self) -> None:
        resource, rid = self._parse_path()

        if resource == "chats" and rid is not None:
            if delete_chat(rid):
                self._send_json(200, {"ok": True})
            else:
                self._send_error_json(404, "Chat not found")
            return

        if resource == "messages" and rid is not None:
            if delete_message(rid):
                self._send_json(200, {"ok": True})
            else:
                self._send_error_json(404, "Message not found")
            return

        self._send_error_json(404, "Not found")

    def _handle_chat_completions(self) -> None:
        """Handle /v1/chat/completions with automatic tool injection and execution."""
        try:
            body = _read_json(self)
            if not isinstance(body, dict):
                raise ValueError("JSON must be an object")
        except ValueError as e:
            self._send_error_json(400, str(e))
            return

        client = self.server.upstream
        stream = bool(body.get("stream"))

        if stream:
            # Use StreamHandler for streaming mode
            def send_headers():
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                # IMPORTANT: close the connection once streaming finishes.
                # If we keep it alive, curl (used by Quickshell) may keep waiting even after [DONE],
                # leaving the UI stuck in "generating" state.
                self.send_header("Connection", "close")
                self.send_header("X-Accel-Buffering", "no")
                self.end_headers()
                # Tell BaseHTTPRequestHandler to close the socket after this request.
                self.close_connection = True
            
            handler = StreamHandler(self.wfile, client, send_headers)
            handler.handle_streaming(body, is_first=True)
            # Ensure connection closes even if upstream/client behavior is odd.
            self.close_connection = True
        else:
            # Use StreamHandler for non-streaming mode
            handler = StreamHandler(self.wfile, client)
            response_data = handler.handle_non_streaming(body)
            
            if "error" in response_data:
                self._send_error_json(502, response_data["error"].get("message", "Unknown error"))
            else:
                raw = json.dumps(response_data, ensure_ascii=False).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)


def main(argv: list) -> int:
    host = _env("II_AI_BACKEND_HOST", "127.0.0.1")
    port_s = _env("II_AI_BACKEND_PORT", "15333")
    try:
        port = int(port_s)
    except ValueError:
        port = 15333

    get_db()

    server = ThreadingHTTPServer((host, port), Handler)
    server.upstream = UpstreamClient()
    server.daemon_threads = True

    print(f"ii AI backend listening on {host}:{port}", file=sys.stderr)

    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
