#!/usr/bin/env bash
# Launch the Talk to Claude v2 voice server (Qwen3-ASR streaming -> tmux).
# Auto-detects the Tailscale IP. Pass extra flags through, e.g.:
#   ./run.sh --port 9000 --token mysecret
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec uv run --project "$ROOT" python "$ROOT/server/voice_server.py" "$@"
