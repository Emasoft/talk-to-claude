#!/usr/bin/env python3
"""
Talk to Claude — v2 streaming voice server.

The iOS app streams raw microphone audio (PCM16, 16 kHz, mono) over a WebSocket.
This server segments utterances with an energy-based VAD, transcribes each
COMPLETED utterance with Whisper-large-v3-turbo (MLX) in BATCH mode, and injects
the recognized text into a running `claude` CLI session inside tmux.

Why batch-per-utterance instead of chunk streaming:
    Measured on an M4 Pro, ASR chunk-streaming (1 s chunks) badly degraded
    accuracy ("Hello Claude ..." -> "Hello, clouds. Please list. ..."), while a
    full BATCH transcribe of the whole utterance was flawless at RTF ~0.16
    (~0.8 s for a 5 s utterance). So we let an energy VAD find utterance
    boundaries (continuous, no push-to-talk) and run one accurate batch
    transcription per utterance. Text lands in Claude ~1-1.5 s after you stop
    speaking.

Security:
    Binds only to the Mac's Tailscale IP by default (auto-detected). Every
    endpoint and the WebSocket require a bearer token. Tailscale (WireGuard)
    encrypts the transport. Text is injected with an argv array +
    `tmux send-keys -l --`, so it can't be interpreted as shell or tmux commands.

Endpoints:
    GET  /health                 -> {"ok": true}                 (no auth)
    GET  /sessions               -> {"sessions": [...]}          (auth)
    GET  /pane?session=&lines=   -> {"pane": "..."}              (auth)
    POST /say {session,text}     -> {"ok": true}                 (auth)   text path
    WS   /stream                 -> audio in, JSON events out    (auth)   voice path

WebSocket protocol (/stream):
    1. Client sends ONE text frame: JSON {"token","session","context"?,"sample_rate"?}
    2. Server replies {"type":"ready", ...} or {"type":"error", ...} then closes.
    3. Client streams binary frames = little-endian PCM16 mono @ sample_rate.
    4. Server emits JSON events:
         {"type":"speech_start"}
         {"type":"final","text": "..."}     (after an utterance is transcribed+injected)
         {"type":"status","text": "..."}
"""

import argparse
import asyncio
import hmac
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import mlx_whisper
from aiohttp import WSMsgType, web

from voice_commands import cheatsheet, interpret, looks_like_hallucination, render

# Baked default — identical to kDefaultToken in the iOS app. Override with
# CLAUDE_VOICE_TOKEN or --token.
DEFAULT_TOKEN = "mMfRuOWn9rGWskJOnI4HkrTwReVtblyg"
# Whisper-large-v3-turbo: strong on BOTH English and Italian (Qwen3-ASR mangled
# Italian), auto-detects language per utterance, ~RTF 0.16 on M4 Pro.
MODEL_ID = "mlx-community/whisper-large-v3-turbo"
SAMPLE_RATE = 16000
MAX_TEXT_LEN = 8000

# Optional Whisper initial_prompt to bias vocabulary. Empty by default so
# per-utterance language auto-detection (English/Italian) stays clean; a hint can
# be set per-connection via the WS config if you want to nudge toward jargon.
DEFAULT_CONTEXT = ""

# Populated in main().
TOKEN = DEFAULT_TOKEN
TMUX = "tmux"
MODEL = MODEL_ID  # the model actually used for transcription (set from --model)
# All MLX work runs on ONE dedicated thread (max_workers=1): the model is loaded
# there and every transcription runs there, so MLX's per-thread Metal stream
# stays consistent. Calling MLX from an arbitrary pooled thread raises
# "There is no Stream(gpu, 1) in current thread". One worker also serializes
# inference and keeps the asyncio event loop unblocked.
ASR_EXECUTOR = ThreadPoolExecutor(max_workers=1, thread_name_prefix="asr")


# --------------------------------------------------------------------------- #
# tmux injection (ported from v1)
# --------------------------------------------------------------------------- #
def tmux(*args, timeout=5):
    try:
        proc = subprocess.run([TMUX, *args], capture_output=True, text=True, timeout=timeout)
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
    text = text.replace("\r", " ").replace("\n", " ").strip()
    if not text:
        return False, "empty text"
    if len(text) > MAX_TEXT_LEN:
        text = text[:MAX_TEXT_LEN]
    # `-l` sends literally; `--` ends option parsing (text starting with '-' is data).
    code, _, err = tmux("send-keys", "-t", session, "-l", "--", text)
    if code != 0:
        return False, err or "send-keys (text) failed"
    code, _, err = tmux("send-keys", "-t", session, "Enter")
    if code != 0:
        return False, err or "send-keys (Enter) failed"
    return True, ""


KEY_MAP = {
    "Enter": ["Enter"],
    "Tab": ["Tab"],
    "Escape": ["Escape"],
    "BSpace": ["BSpace"],
    # "Newline" = a line break in Claude Code WITHOUT submitting. Claude's TUI
    # takes Option/Meta+Enter for that; change M-Enter here if your terminal differs.
    "Newline": ["M-Enter"],
}


def execute_actions(session, actions):
    """Run a verbal-command action list (typed text + key presses) into tmux.
    Unlike inject_text this does NOT auto-press Enter — the prompt is submitted
    only when the user says "invio"/"enter" (which produces an Enter key action)."""
    for kind, value in actions:
        if kind == "type":
            text = value.replace("\r", " ").replace("\n", " ")
            if not text:
                continue
            if len(text) > MAX_TEXT_LEN:
                text = text[:MAX_TEXT_LEN]
            code, _, err = tmux("send-keys", "-t", session, "-l", "--", text)
            if code != 0:
                return False, err or "send-keys (text) failed"
        elif kind == "key":
            keys = KEY_MAP.get(value, [value])
            code, _, err = tmux("send-keys", "-t", session, *keys)
            if code != 0:
                return False, err or f"send-keys ({value}) failed"
        elif kind == "erase":
            # Delete `value` characters to the left (edit modes: delete/replace/undo).
            count = int(value)
            if count > 0:
                code, _, err = tmux("send-keys", "-t", session, "-N", str(count), "BSpace")
                if code != 0:
                    return False, err or "send-keys (erase) failed"
    return True, ""


def capture_pane(session, lines):
    code, out, err = tmux("capture-pane", "-t", session, "-p", "-S", f"-{lines}")
    if code != 0:
        return None, err or "capture-pane failed"
    return out, ""


# --------------------------------------------------------------------------- #
# Energy-based VAD utterance segmenter
# --------------------------------------------------------------------------- #
class UtteranceSegmenter:
    """Feed it float32 [-1, 1] mono samples; it returns a completed utterance's
    audio (np.float32) when a speech segment ends on silence, else None.

    Speech is detected per analysis window via RMS energy. A pre-roll keeps the
    leading edge of speech (which precedes the first above-threshold window), and
    an utterance ends after `silence_hold_sec` of continuous silence following
    speech. Blips shorter than `min_speech_sec` are discarded.
    """

    def __init__(
        self,
        sample_rate=SAMPLE_RATE,
        window_sec=0.03,
        threshold=0.012,
        silence_hold_sec=0.7,
        preroll_sec=0.3,
        min_speech_sec=0.25,
        max_utt_sec=30.0,
    ):
        self.sr = sample_rate
        self.win = max(1, int(window_sec * sample_rate))
        self.threshold = threshold
        self.silence_hold_win = max(1, int(silence_hold_sec / window_sec))
        self.preroll_win = max(0, int(preroll_sec / window_sec))
        self.min_speech_win = max(1, int(min_speech_sec / window_sec))
        self.max_utt_win = max(1, int(max_utt_sec / window_sec))

        self._leftover = np.zeros(0, dtype=np.float32)
        self._preroll: list[np.ndarray] = []
        self._utt: list[np.ndarray] = []
        self._speaking = False
        self._silence_run = 0
        self._speech_win = 0
        self.level = 0.0  # RMS of the most recent window (for UI meters)

    def feed(self, samples: np.ndarray):
        """Process samples; return (events, utterance_or_None).

        events is a list of strings: e.g. ["speech_start"].
        """
        events: list[str] = []
        finished = None
        data = np.concatenate([self._leftover, samples]) if self._leftover.size else samples
        n_full = (len(data) // self.win) * self.win
        windows = data[:n_full].reshape(-1, self.win) if n_full else np.empty((0, self.win), np.float32)
        self._leftover = data[n_full:].copy()

        for idx, w in enumerate(windows):
            rms = float(np.sqrt(np.mean(w * w)) + 1e-12)
            self.level = rms
            is_speech = rms > self.threshold

            if not self._speaking:
                self._preroll.append(w)
                if len(self._preroll) > self.preroll_win:
                    self._preroll.pop(0)
                if is_speech:
                    self._speaking = True
                    self._utt = list(self._preroll)
                    self._preroll = []
                    self._silence_run = 0
                    self._speech_win = 1
                    events.append("speech_start")
            else:
                self._utt.append(w)
                if is_speech:
                    self._silence_run = 0
                    self._speech_win += 1
                else:
                    self._silence_run += 1

                ended = self._silence_run >= self.silence_hold_win
                too_long = len(self._utt) >= self.max_utt_win
                if ended or too_long:
                    if self._speech_win >= self.min_speech_win:
                        finished = np.concatenate(self._utt).astype(np.float32)
                    self._reset()
                    # Keep any audio AFTER this boundary (the start of the next
                    # utterance) instead of dropping it — one utterance per feed().
                    rest = windows[idx + 1:]
                    if rest.size:
                        self._leftover = np.concatenate([rest.reshape(-1), self._leftover])
                    break
        return events, finished

    def _reset(self):
        self._utt = []
        self._preroll = []
        self._speaking = False
        self._silence_run = 0
        self._speech_win = 0


def _load_model(model_id: str):
    """Warm Whisper ON the ASR worker thread (see ASR_EXECUTOR note). mlx_whisper
    caches the model by repo, so this one warm-up primes it and every later
    transcription reuses it on this same thread (keeping the MLX stream stable)."""
    mlx_whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), path_or_hf_repo=model_id)


def transcribe_utterance(audio: np.ndarray, context: str) -> str:
    """Batch-transcribe one utterance with Whisper. Runs on the ASR thread.
    Language is auto-detected per utterance (English / Italian / …). Returns ""
    for silence/noise hallucinations so nothing phantom is injected."""
    opts = {"path_or_hf_repo": MODEL}
    if context:
        opts["initial_prompt"] = context
    result = mlx_whisper.transcribe(audio, **opts)
    text = (result.get("text", "") or "").strip()
    # Drop hallucinations: if EVERY segment reads as non-speech (high
    # no_speech_prob) or very low confidence, treat the whole utterance as silence.
    segs = result.get("segments") or []
    if segs:
        speechy = [
            s for s in segs
            if s.get("no_speech_prob", 0.0) < 0.6 and s.get("avg_logprob", -10.0) > -1.0
        ]
        if not speechy:
            return ""
    if looks_like_hallucination(text):
        return ""
    return text


# --------------------------------------------------------------------------- #
# HTTP helpers
# --------------------------------------------------------------------------- #
def authorized(request) -> bool:
    header = request.headers.get("Authorization", "")
    prefix = "Bearer "
    if not header.startswith(prefix):
        return False
    return hmac.compare_digest(header[len(prefix):], TOKEN)


async def handle_health(request):
    return web.json_response({"ok": True})


async def handle_sessions(request):
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    return web.json_response({"sessions": list_sessions()})


async def handle_pane(request):
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    session = request.query.get("session", "")
    try:
        lines = int(request.query.get("lines", "60"))
    except ValueError:
        lines = 60
    lines = max(1, min(lines, 500))
    if session not in list_sessions():
        return web.json_response({"error": "unknown session"}, status=404)
    pane, err = capture_pane(session, lines)
    if pane is None:
        return web.json_response({"error": err}, status=500)
    return web.json_response({"pane": pane})


async def handle_say(request):
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    try:
        data = await request.json()
    except Exception:
        return web.json_response({"error": "invalid JSON"}, status=400)
    session = data.get("session", "")
    text = data.get("text", "")
    if not isinstance(session, str) or not isinstance(text, str):
        return web.json_response({"error": "session and text must be strings"}, status=400)
    if session not in list_sessions():
        return web.json_response({"error": "unknown session"}, status=404)
    ok, err = inject_text(session, text)
    if not ok:
        return web.json_response({"error": err}, status=500)
    return web.json_response({"ok": True})


# --------------------------------------------------------------------------- #
# WebSocket audio stream
# --------------------------------------------------------------------------- #
_LINE_KEYS = ("line", "undo", "redo", "edit_mode", "edit_target", "edit_repl",
              "case_mode", "spelling")


def _snapshot_modes(m: dict) -> dict:
    """Deep-ish snapshot of the per-connection mode state (lists copied) so an
    edit can be rolled back if tmux injection fails."""
    return {k: (list(m[k]) if isinstance(m.get(k), list) else m.get(k)) for k in _LINE_KEYS}


def _restore_modes(m: dict, snap: dict):
    for k in _LINE_KEYS:
        if k in snap:
            m[k] = list(snap[k]) if isinstance(snap[k], list) else snap[k]


def _reset_line(m: dict):
    """Forget the editable line — used after Enter / auto-send commits a sentence."""
    m["line"] = ""
    m["undo"] = []
    m["redo"] = []
    m["edit_mode"] = None
    m["edit_target"] = []
    m["edit_repl"] = []


async def handle_stream(request):
    ws = web.WebSocketResponse(max_msg_size=8 * 1024 * 1024, heartbeat=30)
    await ws.prepare(request)
    loop = asyncio.get_running_loop()

    # First frame must be the JSON config with token + target session.
    try:
        first = await ws.receive(timeout=15)
    except asyncio.TimeoutError:
        await ws.close(code=4001, message=b"no config")
        return ws
    if first.type != WSMsgType.TEXT:
        await ws.send_json({"type": "error", "error": "expected JSON config first"})
        await ws.close()
        return ws
    try:
        cfg = json.loads(first.data)
    except Exception:
        await ws.send_json({"type": "error", "error": "bad config JSON"})
        await ws.close()
        return ws

    if not hmac.compare_digest(str(cfg.get("token", "")), TOKEN):
        await ws.send_json({"type": "error", "error": "unauthorized"})
        await ws.close(code=4003)
        return ws
    session = str(cfg.get("session", ""))
    if session not in list_sessions():
        await ws.send_json({"type": "error", "error": "unknown session"})
        await ws.close()
        return ws

    context = str(cfg.get("context") or DEFAULT_CONTEXT)
    sample_rate = int(cfg.get("sample_rate") or SAMPLE_RATE)
    if sample_rate != SAMPLE_RATE:
        # Whisper assumes 16 kHz and we don't resample; the app always sends 16 kHz.
        await ws.send_json({"type": "error", "error": f"sample_rate must be {SAMPLE_RATE}"})
        await ws.close()
        return ws
    # Optional tunables from the app: silence_hold = pause length that ends an
    # utterance (the app's "pause threshold"); auto_send submits each utterance.
    try:
        silence_hold = float(cfg.get("silence_hold") or 0.7)
    except (TypeError, ValueError):
        silence_hold = 0.7
    silence_hold = max(0.3, min(silence_hold, 3.0))
    auto_send = bool(cfg.get("auto_send"))

    seg = UtteranceSegmenter(sample_rate=sample_rate, silence_hold_sec=silence_hold)
    modes: dict = {}  # persistent caps/spell + editable-line state for this connection
    await ws.send_json({"type": "ready", "session": session, "sample_rate": sample_rate})
    await ws.send_json({"type": "cheatsheet", "groups": cheatsheet()})
    print(f"[stream] connected -> session={session!r} sr={sample_rate} "
          f"hold={silence_hold}s auto_send={auto_send}", file=sys.stderr)

    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                raw = msg.data
                if len(raw) % 2:                 # PCM16 — an odd byte count is a torn frame
                    raw = raw[: len(raw) - 1]
                if not raw:
                    continue
                pcm = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
                if pcm.size == 0:
                    continue
                events, utt = seg.feed(pcm)
                for ev in events:
                    await ws.send_json({"type": ev})
                if utt is not None:
                    try:
                        text = await loop.run_in_executor(
                            ASR_EXECUTOR, transcribe_utterance, utt, context
                        )
                    except Exception as e:  # noqa: BLE001 - report, don't drop the stream
                        await ws.send_json({"type": "error", "error": f"transcribe failed: {e}"})
                        continue
                    if text:
                        before = _snapshot_modes(modes)   # for change-detect + rollback
                        actions = interpret(text, modes)
                        if auto_send and not (actions and actions[-1] == ("key", "Enter")):
                            actions = actions + [("key", "Enter")]
                            _reset_line(modes)            # auto-submitted -> no longer editable
                        ok, err = execute_actions(session, actions)
                        if not ok:
                            _restore_modes(modes, before)  # C7: revert the optimistic edit
                        await ws.send_json(
                            {"type": "final", "text": text, "rendered": render(actions), "injected": ok}
                            | ({} if ok else {"error": err})
                        )
                        now = (bool(modes.get("spelling")), modes.get("case_mode", "none"),
                               modes.get("edit_mode"))
                        if now != (bool(before["spelling"]), before["case_mode"], before["edit_mode"]):
                            await ws.send_json({"type": "mode", "spell": now[0],
                                                "caps": now[1], "edit": now[2]})
                        print(f"[stream] -> {session}: {text!r} => {render(actions)!r} ok={ok}",
                              file=sys.stderr)
                    else:
                        await ws.send_json({"type": "final", "text": ""})
            elif msg.type == WSMsgType.TEXT:
                # control messages (e.g. {"type":"flush"}) — reserved for later
                continue
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.ERROR):
                break
    finally:
        print("[stream] disconnected", file=sys.stderr)
    return ws


# --------------------------------------------------------------------------- #
# Bootstrap
# --------------------------------------------------------------------------- #
def detect_tailscale_ip():
    for exe in ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale"):
        try:
            proc = subprocess.run([exe, "ip", "-4"], capture_output=True, text=True, timeout=5)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip().splitlines()[0].strip()
    return None


def make_app() -> web.Application:
    app = web.Application()
    app.add_routes(
        [
            web.get("/health", handle_health),
            web.get("/sessions", handle_sessions),
            web.get("/pane", handle_pane),
            web.post("/say", handle_say),
            web.get("/stream", handle_stream),
        ]
    )
    return app


def main():
    global TOKEN, TMUX, MODEL

    parser = argparse.ArgumentParser(description="Talk to Claude v2 voice server")
    parser.add_argument("--host", default=None, help="Bind address (default: Tailscale IP)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("CLAUDE_VOICE_PORT", "8765")))
    parser.add_argument("--token", default=os.environ.get("CLAUDE_VOICE_TOKEN", DEFAULT_TOKEN))
    parser.add_argument("--tmux", default=os.environ.get("TMUX_BIN", "tmux"))
    parser.add_argument("--model", default=MODEL_ID)
    args = parser.parse_args()

    TOKEN = args.token
    TMUX = args.tmux
    MODEL = args.model  # the model actually used for transcription (A1)

    host = args.host or detect_tailscale_ip()
    no_tailscale = host is None
    if no_tailscale:
        # No Tailscale IP and no explicit --host: bind LOOPBACK only — never the
        # LAN/world with just the shared token. Pass --host <ip> to expose it.
        host = "127.0.0.1"

    print(f"Loading Whisper model {args.model} (one-time)…", file=sys.stderr)
    t0 = time.time()
    # Load on the dedicated ASR thread so the model + all inference share one
    # MLX Metal stream.
    ASR_EXECUTOR.submit(_load_model, args.model).result()
    print(f"Model ready in {time.time() - t0:.1f}s", file=sys.stderr)

    print("─" * 64)
    print(" Talk to Claude — v2 voice server")
    print(f"   Listening on : http://{host}:{args.port}   (ws://{host}:{args.port}/stream)")
    print(f"   Token        : {TOKEN}")
    print(f"   Model        : {args.model}")
    sessions = list_sessions()
    print(f"   tmux sessions: {', '.join(sessions) if sessions else '(none found)'}")
    if no_tailscale:
        print("   ⚠️  No Tailscale IP detected — bound to 127.0.0.1 (loopback only).")
        print("       Pass --host <ip> to expose it on a trusted network.")
    print("─" * 64)

    # access_log=None disables aiohttp's per-request logging. Without it, the
    # /pane poll would append a log line forever and grow the log file unbounded
    # on a long-running server. Our own meaningful events (connect/disconnect/
    # utterances) are still printed to stderr.
    web.run_app(make_app(), host=host, port=args.port, print=None, access_log=None)


if __name__ == "__main__":
    main()
