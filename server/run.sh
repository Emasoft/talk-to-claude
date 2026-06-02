#!/usr/bin/env bash
# Convenience launcher for the Talk to Claude receiver.
# Auto-detects the Tailscale IP and starts the stdlib HTTP server.
# Pass extra flags straight through, e.g.:  ./run.sh --port 9000 --token mysecret
set -euo pipefail
cd "$(dirname "$0")"
exec python3 claude_voice_server.py "$@"
