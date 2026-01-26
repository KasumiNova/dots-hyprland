"""Streaming response handler with tool call support for ii AI backend."""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any, Callable, Dict, List, Optional, BinaryIO

from .tools import execute_tool, get_tool_definitions
from .upstream import UpstreamClient, ProxyError


class StreamHandler:
    """
    Handles streaming responses with automatic tool execution.
    Sends events to the client via the provided write function.
    """
    
    def __init__(
        self,
        wfile: BinaryIO,
        client: UpstreamClient,
        send_headers: Optional[Callable[[], None]] = None
    ):
        self.wfile = wfile
        self.client = client
        self.send_headers = send_headers
        self._headers_sent = False
    
    def _write(self, data: bytes) -> bool:
        """Write data to client. Returns False if connection is broken."""
        try:
            self.wfile.write(data)
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError):
            return False
    
    def _send_event(self, event: Dict[str, Any]) -> bool:
        """Send a JSON event to the client."""
        return self._write(f"data: {json.dumps(event)}\n\n".encode())
    
    def _send_error(self, message: str) -> bool:
        """Send an error event to the client."""
        return self._send_event({"type": "error", "message": message})

    @staticmethod
    def _estimate_tokens(text: str) -> int:
        """Very rough token estimate when upstream doesn't provide usage.

        We intentionally keep this stdlib-only. For UI/telemetry it's better than nothing.
        Approximation: ~4 chars per token.
        """
        if not text:
            return 0
        return max(1, (len(text) + 3) // 4)
    
    def handle_streaming(
        self,
        body: Dict[str, Any],
        is_first: bool = True,
        max_iterations: int = 10
    ) -> None:
        """
        Handle streaming response with automatic tool execution.
        
        Recursively continues the conversation if model uses tools.
        """
        # Allow override via env for long agent/tool chains.
        try:
            env_max = int(os.environ.get("II_AI_MAX_TOOL_ITERATIONS", "") or "0")
            if env_max > 0:
                max_iterations = env_max
        except Exception:
            pass

        if max_iterations <= 0:
            # Best-effort usage even on early abort so UI can show ctx/token.
            try:
                prompt_text = json.dumps(body.get("messages", []), ensure_ascii=False)
            except Exception:
                prompt_text = ""
            prompt_tokens = self._estimate_tokens(prompt_text)
            self._send_event({
                "type": "usage",
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": 0,
                    "total_tokens": prompt_tokens,
                },
                "estimated": True,
            })

            self._send_error("Max tool iterations reached (II_AI_MAX_TOOL_ITERATIONS)")
            self._write(b"data: [DONE]\n\n")
            return

        request_id = hex(int(time.time() * 1000))[2:]
        
        # Send headers on first call
        if is_first and self.send_headers and not self._headers_sent:
            self.send_headers()
            self._headers_sent = True
        
        # Auto-inject tools if not provided
        if "tools" not in body or not body.get("tools"):
            body["tools"] = get_tool_definitions()
            body["tool_choice"] = "auto"
        
        try:
            resp = self.client.request_chat_completions(body)
        except ProxyError as e:
            # Best-effort usage even on upstream failure.
            try:
                prompt_text = json.dumps(body.get("messages", []), ensure_ascii=False)
            except Exception:
                prompt_text = ""
            prompt_tokens = self._estimate_tokens(prompt_text)
            self._send_event({
                "type": "usage",
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": 0,
                    "total_tokens": prompt_tokens,
                },
                "estimated": True,
                "request_id": request_id,
            })

            self._send_error(str(e))
            self._write(b"data: [DONE]\n\n")
            return
        
        # Buffer for accumulating tool call data
        tool_call_buffer: Dict[str, Dict[str, Any]] = {}
        collected_content = ""
        collected_reasoning = ""
        collected_tool_calls: List[Dict[str, Any]] = []
        last_usage: Optional[Dict[str, Any]] = None

        # For real-time ctx/token display, send periodic best-effort usage estimates
        # while streaming (throttled to avoid spamming the UI).
        try:
            _prompt_text_for_estimate = json.dumps(body.get("messages", []), ensure_ascii=False)
        except Exception:
            _prompt_text_for_estimate = ""
        _prompt_tokens_estimate = self._estimate_tokens(_prompt_text_for_estimate)
        _last_usage_emit_ts = 0.0

        def _maybe_emit_usage_estimate(force: bool = False) -> None:
            nonlocal _last_usage_emit_ts
            if last_usage is not None:
                # Upstream already provides usage; don't emit estimates anymore.
                return
            now = time.time()
            if not force and (now - _last_usage_emit_ts) < 0.75:
                return
            completion_text = (collected_reasoning or "") + (collected_content or "")
            completion_tokens = self._estimate_tokens(completion_text)
            self._send_event({
                "type": "usage",
                "usage": {
                    "prompt_tokens": _prompt_tokens_estimate,
                    "completion_tokens": completion_tokens,
                    "total_tokens": _prompt_tokens_estimate + completion_tokens,
                },
                "estimated": True,
                "request_id": request_id,
            })
            _last_usage_emit_ts = now
        
        try:
            while True:
                line = resp.readline()
                if not line:
                    break
                
                line_str = line.decode("utf-8") if isinstance(line, bytes) else line
                
                # Parse SSE data
                if line_str.strip().startswith("data:"):
                    data_str = line_str.strip()[5:].strip()
                    if data_str == "[DONE]":
                        # Check if we need to handle tool calls
                        if tool_call_buffer:
                            # Execute all tools and collect results
                            tool_results: Dict[str, Dict[str, Any]] = {}
                            
                            for key, buf in tool_call_buffer.items():
                                if buf.get("name"):
                                    try:
                                        args = json.loads(buf.get("args_str", "{}"))
                                    except json.JSONDecodeError:
                                        args = {}
                                    
                                    collected_tool_calls.append({
                                        "id": buf.get("id", key),
                                        "type": "function",
                                        "function": {
                                            "name": buf["name"],
                                            "arguments": buf.get("args_str", "{}")
                                        }
                                    })
                                    
                                    # Send tool execution event
                                    self._send_event({
                                        "type": "tool_execution",
                                        "tool_call": {
                                            "id": buf.get("id", key),
                                            "name": buf["name"],
                                            "args": args
                                        },
                                        "status": "executing"
                                    })

                                    # Update ctx/token immediately before/at tool execution.
                                    _maybe_emit_usage_estimate(force=True)
                                    
                                    # Execute the tool
                                    result = execute_tool(buf["name"], args)
                                    tool_results[key] = result
                                    
                                    # Send tool result event
                                    self._send_event({
                                        "type": "tool_result",
                                        "tool_call": {
                                            "id": buf.get("id", key),
                                            "name": buf["name"],
                                            "args": args
                                        },
                                        "result": result
                                    })

                                    # Tool finished; emit another estimate (prompt doesn't change in this request,
                                    # but completion might have grown).
                                    _maybe_emit_usage_estimate(force=True)
                            
                            # Build follow-up request with tool results
                            messages = body.get("messages", [])
                            
                            # Add assistant message with tool_calls
                            assistant_msg: Dict[str, Any] = {"role": "assistant"}
                            if collected_reasoning:
                                assistant_msg["reasoning_content"] = collected_reasoning
                            assistant_msg["content"] = collected_content or ""
                            assistant_msg["tool_calls"] = collected_tool_calls
                            messages.append(assistant_msg)
                            
                            # Add tool results
                            for key, buf in tool_call_buffer.items():
                                if buf.get("name") and key in tool_results:
                                    result = tool_results[key]
                                    output = result.get("output", "") if result.get("success") else json.dumps(result)
                                    messages.append({
                                        "role": "tool",
                                        "tool_call_id": buf.get("id", key),
                                        "content": output
                                    })
                            
                            # Make follow-up request by continuing the conversation.
                            body["messages"] = messages
                            try:
                                # Send continuation event
                                self._send_event({"type": "continuation", "status": "starting", "request_id": request_id})

                                # Before switching to the next upstream request, emit an estimate for the next prompt
                                # so the UI can reflect the larger context window immediately.
                                if last_usage is None:
                                    try:
                                        next_prompt_text = json.dumps(body.get("messages", []), ensure_ascii=False)
                                    except Exception:
                                        next_prompt_text = ""
                                    next_prompt_tokens = self._estimate_tokens(next_prompt_text)
                                    self._send_event({
                                        "type": "usage",
                                        "usage": {
                                            "prompt_tokens": next_prompt_tokens,
                                            "completion_tokens": 0,
                                            "total_tokens": next_prompt_tokens,
                                        },
                                        "estimated": True,
                                        "request_id": request_id,
                                    })

                                # IMPORTANT: do NOT issue an extra upstream request here.
                                # The recursive call below will create the next upstream stream.
                                try:
                                    resp.close()
                                except Exception:
                                    pass

                                print(f"[DEBUG] ({request_id}) continuing after tool execution; remaining={max_iterations-1}", file=sys.stderr, flush=True)
                                self.handle_streaming(body, is_first=False, max_iterations=max_iterations - 1)
                                return
                            except ProxyError as e:
                                print(f"[DEBUG] ({request_id}) follow-up error: {e}", file=sys.stderr, flush=True)
                                self._send_event({"type": "error", "message": f"Tool follow-up failed: {e}", "where": "upstream", "request_id": request_id})
                                self._write(b"data: [DONE]\n\n")
                                return
                        else:
                            # No tool calls. If upstream didn't provide usage, emit a best-effort estimate
                            # so the frontend can show token/context window stats.
                            if last_usage is None:
                                try:
                                    prompt_text = json.dumps(body.get("messages", []), ensure_ascii=False)
                                except Exception:
                                    prompt_text = ""
                                completion_text = (collected_reasoning or "") + (collected_content or "")
                                prompt_tokens = self._estimate_tokens(prompt_text)
                                completion_tokens = self._estimate_tokens(completion_text)
                                last_usage = {
                                    "prompt_tokens": prompt_tokens,
                                    "completion_tokens": completion_tokens,
                                    "total_tokens": prompt_tokens + completion_tokens,
                                    "estimated": True,
                                }

                            if isinstance(last_usage, dict) and "prompt_tokens" in last_usage:
                                self._send_event({
                                    "type": "usage",
                                    "usage": {
                                        "prompt_tokens": last_usage.get("prompt_tokens", 0),
                                        "completion_tokens": last_usage.get("completion_tokens", 0),
                                        "total_tokens": last_usage.get("total_tokens", 0),
                                    },
                                    "estimated": bool(last_usage.get("estimated")),
                                    "request_id": request_id,
                                })

                            # Finally forward [DONE]
                            self._write(line if isinstance(line, bytes) else line.encode("utf-8"))
                        break
                    
                    try:
                        chunk = json.loads(data_str)
                        # Capture usage if upstream provides it (some providers send it only in the final chunk).
                        if isinstance(chunk, dict) and isinstance(chunk.get("usage"), dict):
                            u = chunk.get("usage") or {}
                            last_usage = {
                                "prompt_tokens": u.get("prompt_tokens", 0),
                                "completion_tokens": u.get("completion_tokens", 0),
                                "total_tokens": u.get("total_tokens", 0),
                                "estimated": False,
                            }
                        delta = chunk.get("choices", [{}])[0].get("delta", {})
                        
                        # Collect content
                        if delta.get("content"):
                            collected_content += delta["content"]
                        
                        # Collect reasoning_content
                        if delta.get("reasoning_content"):
                            collected_reasoning += delta["reasoning_content"]

                        # Real-time estimate updates while streaming reasoning/content.
                        _maybe_emit_usage_estimate(force=False)
                        
                        # Collect tool calls
                        if delta.get("tool_calls"):
                            for tc in delta["tool_calls"]:
                                idx = tc.get("index", 0)
                                key = f"idx:{idx}"
                                
                                if key not in tool_call_buffer:
                                    tool_call_buffer[key] = {
                                        "id": "",
                                        "name": "",
                                        "args_str": ""
                                    }
                                
                                if tc.get("id"):
                                    tool_call_buffer[key]["id"] = tc["id"]
                                if tc.get("function", {}).get("name"):
                                    tool_call_buffer[key]["name"] = tc["function"]["name"]
                                if tc.get("function", {}).get("arguments"):
                                    tool_call_buffer[key]["args_str"] += tc["function"]["arguments"]
                    except json.JSONDecodeError:
                        pass
                
                # Forward the line to client
                if not self._write(line if isinstance(line, bytes) else line.encode("utf-8")):
                    break
                    
        except Exception as e:
            print(f"[ERROR] ({request_id}) streaming error: {e}", file=sys.stderr, flush=True)
            self._send_event({"type": "error", "message": f"Streaming error: {e}", "where": "backend", "request_id": request_id})
        finally:
            try:
                resp.close()
            except Exception:
                pass
    
    def handle_non_streaming(self, body: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle non-streaming response with tool execution.
        Returns the final response dict.
        """
        # Auto-inject tools if not provided
        if "tools" not in body or not body.get("tools"):
            body["tools"] = get_tool_definitions()
            body["tool_choice"] = "auto"
        
        try:
            resp = self.client.request_chat_completions(body)
            raw = resp.read()
            response_data = json.loads(raw.decode("utf-8"))
        except ProxyError as e:
            return {"error": {"message": str(e)}}
        except Exception as e:
            return {"error": {"message": f"Request failed: {e}"}}
        
        # Check for tool calls
        message = response_data.get("choices", [{}])[0].get("message", {})
        tool_calls = message.get("tool_calls", [])
        
        if tool_calls:
            # Execute tools and continue conversation
            messages = body.get("messages", [])
            messages.append(message)
            
            for tc in tool_calls:
                func = tc.get("function", {})
                tool_name = func.get("name", "")
                try:
                    tool_args = json.loads(func.get("arguments", "{}"))
                except json.JSONDecodeError:
                    tool_args = {}
                
                result = execute_tool(tool_name, tool_args)
                output = result.get("output", "") or json.dumps(result)
                
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.get("id", ""),
                    "content": output
                })
            
            # Make another request with tool results
            body["messages"] = messages
            del body["tools"]  # Don't need tools for follow-up
            try:
                resp2 = self.client.request_chat_completions(body)
                raw = resp2.read()
                resp2.close()
                return json.loads(raw.decode("utf-8"))
            except Exception as e:
                return {"error": {"message": f"Tool follow-up failed: {e}"}}
        
        return response_data
