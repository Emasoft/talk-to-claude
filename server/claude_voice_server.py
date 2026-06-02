#!/usr/bin/env python3
"""
Talk-to-Claude receiver.

Receives transcribed utterances from the Talk to Claude iOS app (over Tailscale)
and injects them into a running `claude` CLI session inside tmux via
`tmux send-keys`. Standard library only — no pip installs.

Security model:
  * Binds ONLY to the Mac's Tailscale IP by default (auto-detected), so the
    socket is not exposed on the LAN or the public internet.
  * Every mutating/listing endpoint requires `Authorization: Bearer <token>`.
  * The transport is plain HTTP, but Tailscale (WireGuard) already encrypts
    every packet end-to-end.
  * Text is injected with an argv array + `tmux send-keys -l --`, so neither the
    shell nor tmux's key-name parser can be tricked by the utterance content.

Endpoints:
  GET  /health                      -> {"ok": true}                (no auth)
  GET  /sessions                    -> {"sessions": ["default", …]} (auth)
  POST /say     {session,text}      -> {"ok": true}                 (auth)
  GET  /pane?session=&lines=        -> {"pane": "…"}                (auth)
"""

import argparse
import hmac
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# Baked default — identical to kDefaultToken in the iOS app's AppSettings.swift,
# so the pair works with zero configuration on first run. Override with
# CLAUDE_VOICE_TOKEN or --token.
DEFAULT_TOKEN = "mMfRuOWn9rGWskJOnI4HkrTwReVtblyg"

MAX_TEXT_LEN = 8000

# Populated in main().
TOKEN = DEFAULT_TOKEN
TMUX = "tmux"


def tmux(*args, timeout=5):
    """Run a tmux command, returning (returncode, stdout, stderr)."""
    try:
        proc = subprocess.run(
            [TMUX, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", "tmux not found on PATH"
    except subprocess.TimeoutExpired:
        return 124, "", "tmux timed out"


def list_sessions():
    code, out, _ = tmux("list-sessions", "-F", "#{session_name}")
    if code != 0:
        return []
    return [line for line in out.splitlines() if line.strip()]


def inject_text(session, text):
    """Type `text` into the session and press Enter. Returns (ok, error)."""
    # Collapse newlines so a multi-line utterance can't submit early / partially.
    text = text.replace("\r", " ").replace("\n", " ").strip()
    if not text:
        return False, "empty text"
    if len(text) > MAX_TEXT_LEN:
        text = text[:MAX_TEXT_LEN]

    # `-l` sends the bytes literally (no key-name interpretation); `--` ends
    # option parsing so text beginning with '-' is treated as data.
    code, _, err = tmux("send-keys", "-t", session, "-l", "--", text)
    if code != 0:
        return False, err or "send-keys (text) failed"
    code, _, err = tmux("send-keys", "-t", session, "Enter")
    if code != 0:
        return False, err or "send-keys (Enter) failed"
    return True, ""


def capture_pane(session, lines):
    code, out, err = tmux("capture-pane", "-t", session, "-p", "-S", f"-{lines}")
    if code != 0:
        return None, err or "capture-pane failed"
    return out, ""


class Handler(BaseHTTPRequestHandler):
    server_version = "ClaudeVoice/1.0"

    # ---- helpers -------------------------------------------------------

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not header.startswith(prefix):
            return False
        presented = header[len(prefix):]
        return hmac.compare_digest(presented, TOKEN)

    def _require_auth(self):
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return False
        return True

    def _valid_session(self, session):
        return bool(session) and session in list_sessions()

    # ---- routes --------------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/health":
            self._send_json(200, {"ok": True})
            return

        if path == "/sessions":
            if not self._require_auth():
                return
            self._send_json(200, {"sessions": list_sessions()})
            return

        if path == "/pane":
            if not self._require_auth():
                return
            qs = parse_qs(parsed.query)
            session = (qs.get("session") or [""])[0]
            try:
                lines = int((qs.get("lines") or ["60"])[0])
            except ValueError:
                lines = 60
            lines = max(1, min(lines, 500))
            if not self._valid_session(session):
                self._send_json(404, {"error": "unknown session"})
                return
            pane, err = capture_pane(session, lines)
            if pane is None:
                self._send_json(500, {"error": err})
                return
            self._send_json(200, {"pane": pane})
            return

        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/say":
            self._send_json(404, {"error": "not found"})
            return
        if not self._require_auth():
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, {"error": "invalid JSON"})
            return

        session = data.get("session", "")
        text = data.get("text", "")
        if not isinstance(session, str) or not isinstance(text, str):
            self._send_json(400, {"error": "session and text must be strings"})
            return
        if not self._valid_session(session):
            self._send_json(404, {"error": "unknown session"})
            return

        ok, err = inject_text(session, text)
        if not ok:
            self._send_json(500, {"error": err})
            return
        self._send_json(200, {"ok": True})

    # Quieter, single-line access log. Keep the base class parameter name.
    def log_message(self, format, *args):  # noqa: A002 - matches BaseHTTPRequestHandler
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def detect_tailscale_ip():
    """Return this Mac's Tailscale IPv4, or None if it can't be determined."""
    candidates = [
        "tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
    ]
    for exe in candidates:
        try:
            proc = subprocess.run(
                [exe, "ip", "-4"],
                capture_output=True, text=True, timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        if proc.returncode == 0:
            ip = proc.stdout.strip().splitlines()[0].strip() if proc.stdout.strip() else ""
            if ip:
                return ip
    return None


def main():
    global TOKEN, TMUX

    parser = argparse.ArgumentParser(description="Talk to Claude receiver")
    parser.add_argument("--host", default=None,
                        help="Bind address (default: auto-detected Tailscale IP)")
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("CLAUDE_VOICE_PORT", "8765")))
    parser.add_argument("--token",
                        default=os.environ.get("CLAUDE_VOICE_TOKEN", DEFAULT_TOKEN))
    parser.add_argument("--tmux", default=os.environ.get("TMUX_BIN", "tmux"),
                        help="Path to the tmux binary")
    args = parser.parse_args()

    TOKEN = args.token
    TMUX = args.tmux

    host = args.host or detect_tailscale_ip()
    insecure_bind = False
    if not host:
        host = "0.0.0.0"
        insecure_bind = True

    server = ThreadingHTTPServer((host, args.port), Handler)

    print("─" * 60)
    print(" Talk to Claude — receiver running")
    print(f"   Listening on : http://{host}:{args.port}")
    print(f"   Token        : {TOKEN}")
    sessions = list_sessions()
    print(f"   tmux sessions: {', '.join(sessions) if sessions else '(none found)'}")
    if insecure_bind:
        print("   ⚠️  Could not detect a Tailscale IP — bound to 0.0.0.0 (all")
        print("       interfaces). Pass --host <tailscale-ip> to restrict it.")
    print("   In the iOS app's Settings, set the IP, port and token above.")
    print("─" * 60)
    print(" Ctrl-C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
        server.shutdown()


if __name__ == "__main__":
    main()
