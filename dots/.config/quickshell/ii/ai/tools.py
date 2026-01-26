"""Tool definitions and execution for ii AI backend."""

from __future__ import annotations

import json
import os
import subprocess
from typing import Any, Dict, List


def get_tool_definitions() -> List[Dict[str, Any]]:
    """Return all available tool definitions in OpenAI format."""
    return [
        {
            "type": "function",
            "function": {
                "name": "run_shell_command",
                "description": "Run a shell command in bash and get its output. Use this for quick commands. The 'command' argument is REQUIRED.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "command": {
                            "type": "string",
                            "description": "The bash command to run (REQUIRED)"
                        }
                    },
                    "required": ["command"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "get_shell_config",
                "description": "Get the desktop shell configuration file contents",
                "parameters": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "set_shell_config",
                "description": "Set a field in the desktop shell configuration file. Must use after get_shell_config.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "key": {
                            "type": "string",
                            "description": "The config key path, e.g. 'appearance.theme'"
                        },
                        "value": {
                            "type": "string",
                            "description": "The value to set"
                        }
                    },
                    "required": ["key", "value"]
                }
            }
        }
    ]


def execute_tool(tool_name: str, args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Execute a tool and return the result.
    Returns: {"success": bool, "output": str, "error": str | None}
    """
    if tool_name == "run_shell_command":
        return _run_shell_command(args)
    elif tool_name == "get_shell_config":
        return _get_shell_config(args)
    elif tool_name == "set_shell_config":
        return _set_shell_config(args)
    elif tool_name == "switch_to_search_mode":
        return {
            "success": True,
            "output": "Switched to search mode. Continue with the user's request.",
            "error": None,
            "action": "switch_mode",
            "mode": "search"
        }
    else:
        return {
            "success": False,
            "output": "",
            "error": f"Unknown tool: {tool_name}"
        }


def _run_shell_command(args: Dict[str, Any]) -> Dict[str, Any]:
    """Execute a shell command."""
    command = args.get("command")
    if not command:
        return {
            "success": False,
            "output": "",
            "error": "Missing required argument: command",
            "expected": {"command": "<string, bash command>"},
            "example": {"command": "fastfetch"}
        }
    try:
        result = subprocess.run(
            ["bash", "-c", command],
            capture_output=True,
            text=True,
            timeout=60,
            cwd=os.path.expanduser("~")
        )
        output = result.stdout
        if result.stderr:
            output += f"\n[stderr]\n{result.stderr}"
        output += f"\n\n[exit code: {result.returncode}]"
        return {
            "success": result.returncode == 0,
            "output": output,
            "error": None if result.returncode == 0 else f"Command exited with code {result.returncode}"
        }
    except subprocess.TimeoutExpired:
        return {
            "success": False,
            "output": "",
            "error": "Command timed out after 60 seconds"
        }
    except Exception as e:
        return {
            "success": False,
            "output": "",
            "error": str(e)
        }


def _get_shell_config(args: Dict[str, Any]) -> Dict[str, Any]:
    """Get the desktop shell configuration."""
    config_path = os.path.expanduser("~/.config/illogical-impulse/config.json")
    try:
        with open(config_path, "r") as f:
            config = json.load(f)
        return {
            "success": True,
            "output": json.dumps(config, indent=2),
            "error": None
        }
    except FileNotFoundError:
        return {
            "success": False,
            "output": "{}",
            "error": "Config file not found"
        }
    except Exception as e:
        return {
            "success": False,
            "output": "",
            "error": str(e)
        }


def _set_shell_config(args: Dict[str, Any]) -> Dict[str, Any]:
    """Set a value in the desktop shell configuration."""
    key = args.get("key")
    value = args.get("value")
    if not key or value is None:
        return {
            "success": False,
            "output": "",
            "error": "Missing required arguments: key and value"
        }
    config_path = os.path.expanduser("~/.config/illogical-impulse/config.json")
    try:
        with open(config_path, "r") as f:
            config = json.load(f)
        
        # Navigate to nested key and set value
        keys = key.split(".")
        current = config
        for k in keys[:-1]:
            if k not in current:
                current[k] = {}
            current = current[k]
        current[keys[-1]] = value
        
        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)
        
        return {
            "success": True,
            "output": f"Set {key} = {value}",
            "error": None
        }
    except Exception as e:
        return {
            "success": False,
            "output": "",
            "error": str(e)
        }
