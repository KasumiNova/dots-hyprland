# ii AI backend (MVP)

This is a tiny local HTTP proxy that exposes an OpenAI-compatible endpoint so the QML frontend can keep using the existing OpenAI streaming parser.

## Endpoints

- `GET /v1/health`
  - Returns current upstream base URL and whether API key is present.

- `POST /v1/chat/completions`
  - OpenAI-compatible request body.
  - If `stream: true`, returns `text/event-stream` and forwards upstream SSE.

## Environment

- `OPENAI_BASE_URL`
  - Example (DeepSeek): `https://api.deepseek.com` (no `/v1`)

- `OPENAI_API_KEY`
  - Provider API key.

- `II_AI_BACKEND_HOST` (optional)
  - Default: `127.0.0.1`

- `II_AI_BACKEND_PORT` (optional)
  - Default: `15333`

## Notes

- Stdlib-only (no Python dependencies).
- Designed to be started/managed by Quickshell.
