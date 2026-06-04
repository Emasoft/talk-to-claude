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
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import unicodedata

import numpy as np
import iterm2
import mlx.core as mx
import mlx_whisper
from parakeet_mlx import from_pretrained as _parakeet_from_pretrained
from parakeet_mlx import audio as _parakeet_audio
from aiohttp import WSMsgType, web

from voice_commands import cheatsheet, interpret, looks_like_hallucination, render

# Baked default — identical to kDefaultToken in the iOS app. Override with
# CLAUDE_VOICE_TOKEN or --token.
DEFAULT_TOKEN = "mMfRuOWn9rGWskJOnI4HkrTwReVtblyg"
# Two selectable ASR backends (--backend):
#  • parakeet (DEFAULT): NVIDIA Parakeet TDT 0.6b v3 on MLX — 25 European
#    languages incl. Italian, RNN-T, ~23× faster than Whisper, near-ZERO
#    hallucinations (no per-utterance language mis-detection, clean on disfluent
#    "thinking out loud" dictation).
#  • whisper: Whisper-large-v3-turbo — 99 languages, batch, more hallucination-
#    prone; kept as a fallback and for non-European languages.
WHISPER_MODEL_ID = "mlx-community/whisper-large-v3-turbo"
PARAKEET_MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"
DEFAULT_BACKEND = "parakeet"
ALLOWED_LANGS = {"en", "it"}   # Whisper-only: drop other-language noise hallucinations
SAMPLE_RATE = 16000
MAX_TEXT_LEN = 8000

# Optional Whisper initial_prompt to bias vocabulary (Whisper backend only).
DEFAULT_CONTEXT = ""

# In prefix mode, give Whisper a LIGHT vocabulary hint so it leans toward the command
# keywords ("start" not "third") instead of their phonetic neighbours. Keep it to a
# single mention of each word: an earlier version repeated "command … start … stop"
# in example phrases and Whisper began HALLUCINATING "command" everywhere (turning
# "test"/"hello" into "command") and even looping tokens. One mention each is enough
# to bias recognition without over-priming.
# NB: keep this prompt LOWERCASE and COMMA-FREE. Whisper copies the prompt's
# punctuation/casing style into its output — a comma-separated list made it sprinkle
# commas between every spoken word ("deploy" -> "deploy,"), and capitalised words made
# it capitalise. A lowercase space-separated list biases the vocabulary without
# dragging punctuation or capitals into the transcription.
COMMAND_CONTEXT = (
    "terminal voice commands you may hear: command start stop caps spell number "
    "delete replace backword undo redo slash dot dash colon enter backspace space "
    "tab escape question mark"
)

# Populated in main().
TOKEN = DEFAULT_TOKEN
TMUX = "tmux"
BACKEND = DEFAULT_BACKEND
MODEL = ""        # resolved to the active backend's model id in main()
PARAKEET = None   # loaded ParakeetTDT (on the ASR thread) when BACKEND == "parakeet"

# ── optional LLM correction (--correct) ──────────────────────────────────────
# A small local instruct model (mlx-lm) fixes ASR mis-transcriptions — mis-heard
# technical/code terms, homophones, accent errors — BEFORE the text is injected.
# 3B + few-shot catches the hard phonetic mis-hearings (strap→Stripe,
# off-indication→authentication) at ~0.4s/utterance without over-correcting clean
# text. Runs on the same ASR thread as transcription (one MLX Metal stream).
CORRECT_MODEL_ID = "mlx-community/gemma-3-4b-it-4bit"   # bilingual EN+IT (verified), ~0.6s
CORRECT_ENABLED = False  # OPT-IN: a small LLM rewriting disfluent/command speech hallucinates
                         # (—it's safe only with the word-overlap gate in correct_text). --correct enables.
CORRECT_VOCAB = ""       # optional known-terms hint (--correct-vocab "Stripe, tmux, MLX")
CORRECTOR = None         # (model, tokenizer) loaded lazily on the ASR thread
_CORRECT_SAMPLER = None
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


def _claude_command_names() -> set[str]:
    """The names Claude Code shows up as in `#{pane_current_command}`. The launcher
    is a single binary named by its version (e.g. '2.1.161'), so we read the
    installed-versions directory — version-independent, new releases just work."""
    names: set[str] = set()
    cand = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
    try:
        real = os.path.realpath(cand)
        if os.path.exists(real):
            names.add(os.path.basename(real))               # the running version
            vdir = os.path.dirname(real)                    # .../claude/versions
            if os.path.basename(vdir) == "versions" and os.path.isdir(vdir):
                names |= {d for d in os.listdir(vdir) if d and not d.startswith(".")}
    except OSError:
        pass
    return names


def _aimaestro_session_names() -> set[str]:
    """tmux session names owned by ai-maestro agents — excluded for now (a dedicated
    TalkToClaude variant will drive those). Read from the agent registry."""
    path = os.path.expanduser("~/.aimaestro/agents/registry.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return set()
    agents = data.get("agents", []) if isinstance(data, dict) else data
    names: set[str] = set()
    if isinstance(agents, list):
        for a in agents:
            if isinstance(a, dict):
                for key in ("name", "label"):
                    v = a.get(key)
                    if isinstance(v, str) and v:
                        names.add(v)
    return names


def _folder_leaf(cwd: str) -> str:
    """Project-folder name from a cwd (the recognizable label in the app list)."""
    p = cwd.rstrip("/") or cwd
    return os.path.basename(p) or p


def _discover_tmux() -> list[dict]:
    """Claude instances in tmux (excluding ai-maestro). Targets are 'tmux:' prefixed."""
    cmd_names = _claude_command_names()
    if not cmd_names:
        return []
    excluded = _aimaestro_session_names()
    fields = ("session_name", "window_index", "pane_index",
              "pane_current_command", "pane_current_path")
    fmt = "\t".join("#{" + f + "}" for f in fields)
    code, out, _ = tmux("list-panes", "-a", "-F", fmt)
    if code != 0:
        return []
    found: list[dict] = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        sess, win, pane, cmd, cwd = parts[:5]
        if cmd not in cmd_names or sess in excluded:
            continue
        target = f"tmux:{sess}:{win}.{pane}"
        found.append({"id": target, "kind": "tmux", "label": sess,
                      "cwd": cwd, "title": sess, "target": target})
    counts: dict[str, int] = {}
    for s in found:
        counts[s["label"]] = counts.get(s["label"], 0) + 1
    for s in found:
        if counts[s["label"]] > 1:
            s["label"] = f"{s['label']} ({s['cwd'].rsplit('/', 1)[-1]})"
    return found


def _norm_tty(tty: str) -> str:
    t = (tty or "").strip()
    return t[5:] if t.startswith("/dev/") else t


def _claude_procs_by_tty(need_cwd: bool = True) -> dict[str, str]:
    """Map normalized tty -> working dir for every tab where `claude` is the
    FOREGROUND process. Two safety filters matter here: (1) the process must be
    named 'claude' (a bare shell prompt waiting to launch claude has none, so it's
    excluded), and (2) its stat must carry '+' (foreground process group) — if claude
    is suspended (Ctrl-Z) or backgrounded, the shell has the foreground and dictated
    keystrokes would run as SHELL COMMANDS, so such tabs are excluded too."""
    names = {"claude"} | _claude_command_names()
    try:
        out = subprocess.run(["ps", "-axo", "pid=,tty=,stat=,comm="],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    pid_tty: list[tuple[str, str]] = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        pid, tty, stat, comm = parts
        if tty in ("?", "??", "-") or not comm:
            continue
        if "+" not in stat:        # not the foreground process — keystrokes would
            continue               # hit whatever IS foreground (the shell). Skip.
        if comm in names or os.path.basename(comm) in names:
            pid_tty.append((pid, _norm_tty(tty)))
    if not pid_tty:
        return {}
    if not need_cwd:                            # iTerm supplies cwd via its `path` variable;
        return {tty: "" for _, tty in pid_tty}  # skip lsof (it can hang on a busy machine).
    cwds = _lsof_cwds([p for p, _ in pid_tty])
    return {tty: cwds.get(pid, "") for pid, tty in pid_tty}


def _lsof_cwds(pids: list[str]) -> dict[str, str]:
    try:
        out = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fpn", "-p", ",".join(pids)],
                             capture_output=True, text=True, timeout=8).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    cwds: dict[str, str] = {}
    cur = None
    for line in out.splitlines():
        if line.startswith("p"):
            cur = line[1:].strip()
        elif line.startswith("n") and cur:
            cwds[cur] = line[1:].strip()
    return cwds


def _app_running(app_bundle_marker: str) -> bool:
    """True if an app whose executable path contains `app_bundle_marker` is running.
    Used to avoid LAUNCHING iTerm/Terminal when querying them (we only ask if up)."""
    try:
        out = subprocess.run(["ps", "-axo", "command="],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return any(app_bundle_marker in line for line in out.splitlines())


def _osascript(script: str, timeout: int = 3) -> tuple[int, str]:
    try:
        p = subprocess.run(["osascript", "-e", script],
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.SubprocessError):
        return 1, ""


# Circuit breaker: a terminal whose scripting bridge hangs (e.g. the iTerm 3.7 beta,
# which routes automation through its Python API and lets AppleScript time out) must
# not slow down /sessions on every poll. After a failure we skip that app for a while,
# then retry — so it self-heals if the user fixes/enables scripting.
_GUI_COOLDOWN: dict[str, float] = {}
_GUI_COOLDOWN_SEC = 30.0


def _gui_skipped(marker: str) -> bool:
    return time.monotonic() < _GUI_COOLDOWN.get(marker, 0.0)


def _gui_failed(marker: str) -> None:
    _GUI_COOLDOWN[marker] = time.monotonic() + _GUI_COOLDOWN_SEC


# ── iTerm2 Python API — the working automation channel (the 3.7-beta AppleScript
# bridge times out). One persistent connection, lazily (re)created; the breaker
# guards the connect so a disabled/locked API can't stall discovery. ─────────────
_ITERM_CONN = None


async def _iterm_connection():
    global _ITERM_CONN
    if _ITERM_CONN is not None:
        return _ITERM_CONN
    if _gui_skipped("iterm") or not _app_running("/iTerm.app/"):
        return None
    try:
        _ITERM_CONN = await asyncio.wait_for(iterm2.Connection.async_create(), timeout=4)
    except Exception:  # noqa: BLE001 - API off / not approved / iTerm gone
        _gui_failed("iterm")
        _ITERM_CONN = None
    return _ITERM_CONN


# Raw bytes a key produces in the TUI — sent verbatim via async_send_text so Enter,
# arrows (menu/history nav), Esc, Backspace and the no-submit newline all work.
_KEY_BYTES = {
    "Enter": "\r",
    "Tab": "\t",
    "Escape": "\x1b",
    "BSpace": "\x7f",
    "Up": "\x1b[A",
    "Down": "\x1b[B",
    "Newline": "\x1b\r",   # Meta+Enter = newline without submitting
}


def _actions_to_text(actions) -> str:
    parts: list[str] = []
    for kind, value in actions:
        if kind == "type":
            parts.append(value.replace("\r", " ").replace("\n", " "))
        elif kind == "key":
            parts.append(_KEY_BYTES.get(value, ""))
        elif kind == "erase":
            parts.append("\x7f" * int(value))
    text = "".join(parts)
    return text[:MAX_TEXT_LEN] if len(text) > MAX_TEXT_LEN else text


_TERMINAL_LIST = (
    'tell application "Terminal"\n'
    '  set out to ""\n'
    '  repeat with w in windows\n'
    '    set wid to id of w\n'
    '    set i to 0\n'
    '    repeat with t in tabs of w\n'
    '      set i to i + 1\n'
    '      set ttyv to ""\n'
    '      try\n'
    '        set ttyv to tty of t\n'
    '      end try\n'
    '      set ttl to ""\n'
    '      try\n'
    '        set ttl to custom title of t\n'
    '      end try\n'
    '      set out to out & wid & tab & i & tab & ttyv & tab & ttl & linefeed\n'
    '    end repeat\n'
    '  end repeat\n'
    '  return out\n'
    'end tell\n'
)


async def _discover_iterm_api(claude_ttys: set[str]) -> list[dict]:
    """iTerm2 tabs whose tty hosts a claude process. id/tty/cwd(`path`)/title come
    straight from the Python API — no AppleScript, no lsof for the cwd."""
    if not claude_ttys:
        return []
    conn = await _iterm_connection()
    if conn is None:
        return []
    global _ITERM_CONN
    try:
        app = await asyncio.wait_for(iterm2.async_get_app(conn), timeout=4)
        found: list[dict] = []
        for window in app.windows:
            for tab in window.tabs:
                for s in tab.sessions:
                    tty = _norm_tty(await s.async_get_variable("tty") or "")
                    if tty not in claude_ttys:
                        continue
                    cwd = await s.async_get_variable("path") or ""
                    title = (await s.async_get_variable("autoName") or "").strip()
                    target = f"iterm:{s.session_id}"
                    found.append({"id": target, "kind": "iterm",
                                  "label": _folder_leaf(cwd) or title or "iTerm",
                                  "cwd": cwd, "title": title, "target": target})
        return found
    except Exception:  # noqa: BLE001 - drop the (maybe stale) connection; reconnect next
        _ITERM_CONN = None   # poll. If the reconnect itself fails, the breaker trips there —
        return []            # a one-off read error must NOT block injection/focus for 30s.


async def _iterm_send(session_id: str, actions) -> tuple[bool, str]:
    """Inject an action list into one iTerm2 session — full fidelity (text + raw key
    sequences) via async_send_text, no forced submit."""
    conn = await _iterm_connection()
    if conn is None:
        return False, "iTerm API not connected"
    global _ITERM_CONN
    try:
        app = await iterm2.async_get_app(conn)
        sess = app.get_session_by_id(session_id)
        if sess is None:
            return False, "iTerm session not found (closed?)"
        text = _actions_to_text(actions)
        if text:
            await sess.async_send_text(text)
        return True, ""
    except Exception as e:  # noqa: BLE001
        _ITERM_CONN = None
        return False, f"iTerm send failed: {e}"


async def _focus_target(target: str) -> tuple[bool, str]:
    """Bring the selected Claude's tab to the front on the Mac so the monitor shows
    the session you're talking to. iTerm: select tab + raise window (API) + activate
    the app. tmux/Terminal: best effort."""
    kind, addr = _split_target(target)
    if kind == "iterm":
        conn = await _iterm_connection()
        if conn is None:
            return False, "iTerm API not connected"
        global _ITERM_CONN
        try:
            app = await iterm2.async_get_app(conn)
            sess = app.get_session_by_id(addr)
            if sess is None:
                return False, "iTerm session not found (closed?)"
            # Covered-by-another-tab and split-pane (claude + the iTerm browser pane)
            # cases: explicitly select the session's tab too (best-effort, a no-op if
            # the API lacks it), then activate the pane + raise the window. Re-tapping
            # the already-selected Claude re-runs all of this, so a tab buried behind
            # others or split for the browser is brought back to the front.
            try:
                for w in app.windows:
                    for t in w.tabs:
                        if any(x.session_id == addr for x in t.sessions):
                            await t.async_select()
                            break
            except Exception:  # noqa: BLE001
                pass
            await sess.async_activate(select_tab=True, order_window_front=True)
            # The API raises the window WITHIN iTerm; `open -b` makes iTerm the active
            # app so the monitor actually shows it. Best-effort — the tab is already
            # raised, so a hiccup here must not report the focus as failed.
            try:
                await asyncio.get_running_loop().run_in_executor(
                    None, lambda: subprocess.run(["open", "-b", "com.googlecode.iterm2"],
                                                 capture_output=True, timeout=4))
            except Exception:  # noqa: BLE001
                pass
            return True, ""
        except Exception as e:  # noqa: BLE001
            _ITERM_CONN = None
            return False, f"iTerm focus failed: {e}"
    if kind == "tmux":
        # Select the window + pane (a detached session has no attached client to show).
        code, _, err = tmux("select-window", "-t", addr)
        tmux("select-pane", "-t", addr)
        return (code == 0), (err or "")
    if kind == "terminal":
        try:
            wid, idx = addr.split(".", 1)
        except ValueError:
            return False, "bad terminal target"
        code, out = _osascript(
            'tell application "Terminal" to activate\n'
            f'tell application "Terminal" to set selected of tab {idx} of window id {wid} to true')
        return (code == 0), out.strip()
    return False, "unknown target kind"


def _discover_terminal(proc_by_tty: dict[str, str]) -> list[dict]:
    if not proc_by_tty or _gui_skipped("terminal") or not _app_running("/Terminal.app/"):
        return []
    code, out = _osascript(_TERMINAL_LIST)
    if code != 0:
        _gui_failed("terminal")
        return []
    found: list[dict] = []
    for line in out.splitlines():
        parts = line.split("\t", 3)
        if len(parts) < 4:
            continue
        wid, idx, tty, title = parts[0], parts[1], _norm_tty(parts[2]), parts[3]
        if tty not in proc_by_tty:
            continue
        cwd = proc_by_tty[tty]
        target = f"terminal:{wid}.{idx}"
        found.append({"id": target, "kind": "terminal",
                      "label": _folder_leaf(cwd) or title or "Terminal",
                      "cwd": cwd, "title": title, "target": target})
    return found


_SESS_CACHE: dict = {"ts": 0.0, "val": []}
_SESS_TTL = 2.0


async def discover_claude_sessions() -> list[dict]:
    """Every running Claude Code instance the Mac can find — tmux (excluding
    ai-maestro), plus iTerm2 tabs (via the Python API) and Terminal.app tabs. Each:
    {id, kind, label, cwd, title, target}. `target` is kind-prefixed so injection
    routes correctly. Cached briefly (the app polls every few seconds) and
    breaker-guarded so a hung GUI terminal can't stall the call."""
    now = time.monotonic()
    if now - _SESS_CACHE["ts"] < _SESS_TTL:
        return _SESS_CACHE["val"]
    # Terminal.app needs cwd from lsof (no API); iTerm uses its own `path` variable —
    # so only pay for lsof when Terminal could actually contribute a session.
    term_active = not _gui_skipped("terminal") and _app_running("/Terminal.app/")
    proc_by_tty = _claude_procs_by_tty(need_cwd=term_active)   # keys = foreground-claude ttys
    sessions = _discover_tmux()
    sessions += await _discover_iterm_api(set(proc_by_tty))
    if term_active:
        sessions += _discover_terminal(proc_by_tty)
    _SESS_CACHE["ts"] = now
    _SESS_CACHE["val"] = sessions
    return sessions


def tmux_target_exists(target: str) -> bool:
    """True if a tmux session/pane target (no 'tmux:' prefix) is a live pane."""
    if not target:
        return False
    code, _, _ = tmux("display-message", "-t", target, "-p", "ok")
    return code == 0


async def target_exists(target: str) -> bool:
    """Validate any kind-prefixed target before accepting a stream connection."""
    kind, addr = _split_target(target)
    if kind == "tmux":
        return tmux_target_exists(addr)
    sessions = await discover_claude_sessions()
    return any(s["target"] == target for s in sessions)


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
    "Up": ["Up"],      # navigate menus (AskUserQuestion) + prompt history
    "Down": ["Down"],
    # "Newline" = a line break in Claude Code WITHOUT submitting. Claude's TUI
    # takes Option/Meta+Enter for that; change M-Enter here if your terminal differs.
    "Newline": ["M-Enter"],
}


def _split_target(target: str) -> tuple[str, str]:
    """('tmux'|'iterm'|'terminal', address). A bare value (manual entry) is tmux."""
    for kind in ("tmux", "iterm", "terminal"):
        prefix = kind + ":"
        if target.startswith(prefix):
            return kind, target[len(prefix):]
    return "tmux", target


async def execute_actions(target, actions):
    """Inject a verbal-command action list (typed text + key presses) into the
    selected Claude, routed by target kind. Does NOT auto-press Enter — submission
    happens only when the user says "invio"/"enter" (an Enter key action)."""
    kind, addr = _split_target(target)
    if kind == "iterm":
        return await _iterm_send(addr, actions)
    if kind == "terminal":
        return _terminal_execute(addr, actions)
    return _tmux_execute(addr, actions)


def _tmux_execute(session, actions):
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
            count = int(value)
            if count > 0:
                code, _, err = tmux("send-keys", "-t", session, "-N", str(count), "BSpace")
                if code != 0:
                    return False, err or "send-keys (erase) failed"
    return True, ""


def _as_applescript_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _terminal_execute(addr, actions):
    """Inject into a Terminal.app tab. Terminal's AppleScript can only `do script`,
    which RUNS (submits) the text — so no partial text, keys, or edits. We send the
    utterance's typed text as one submitted line (effectively auto-send); bare-key
    utterances (arrows/escape) are no-ops. iTerm/tmux have no such limit."""
    text = "".join(v.replace("\r", " ").replace("\n", " ")
                   for k, v in actions if k == "type")
    if not text.strip():
        return True, ""  # nothing typable for Terminal.app to submit
    if len(text) > MAX_TEXT_LEN:
        text = text[:MAX_TEXT_LEN]
    try:
        wid, idx = addr.split(".", 1)
    except ValueError:
        return False, "bad terminal target"
    script = (f'tell application "Terminal" to do script {_as_applescript_str(text)} '
              f"in tab {idx} of window id {wid}")
    code, out = _osascript(script)
    if code != 0:
        return False, out.strip() or "Terminal do script failed"
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


def _load_model(backend: str, model_id: str):
    """Warm the ASR model ON the ASR worker thread (see ASR_EXECUTOR note) so the
    model and every later transcription share one MLX Metal stream. Both backends
    cache by repo, so this single warm-up primes the model."""
    global PARAKEET
    warm = np.zeros(SAMPLE_RATE, dtype=np.float32)
    if backend == "parakeet":
        PARAKEET = _parakeet_from_pretrained(model_id)
        PARAKEET.generate(_parakeet_audio.get_logmel(mx.array(warm), PARAKEET.preprocessor_config))
    else:
        mlx_whisper.transcribe(warm, path_or_hf_repo=model_id)


def transcribe_utterance(audio: np.ndarray, context: str) -> str:
    """Batch-transcribe one utterance on the ASR thread. Dispatches to the active
    backend. Returns "" for silence/noise so nothing phantom is injected."""
    if BACKEND == "parakeet":
        return _transcribe_parakeet(audio)
    return _transcribe_whisper(audio, context)


def _is_latin(ch: str) -> bool:
    try:
        return "LATIN" in unicodedata.name(ch)
    except ValueError:
        return False


def _transcribe_parakeet(audio: np.ndarray) -> str:
    """Parakeet TDT 0.6b v3 (25 EU langs incl. IT, RNN-T). Returns empty text on
    silence on its own. Also drops NON-LATIN output: the multilingual model
    auto-detects language per utterance (no override in parakeet-mlx) and mis-detects
    accented/noisy speech as a non-Latin language (e.g. Russian/Cyrillic). The user
    only dictates Latin-script English + Italian, so a predominantly non-Latin
    transcription is a mis-detection, not real speech — drop it."""
    mel = _parakeet_audio.get_logmel(mx.array(audio), PARAKEET.preprocessor_config)
    results = PARAKEET.generate(mel)
    text = (results[0].text if results else "").strip()
    if not text or looks_like_hallucination(text):
        return ""
    letters = [c for c in text if c.isalpha()]
    if letters and sum(_is_latin(c) for c in letters) / len(letters) < 0.5:
        print(f"[stream] dropped non-Latin (lang mis-detect): {text!r}", file=sys.stderr)
        return ""
    return text


def _transcribe_whisper(audio: np.ndarray, context: str) -> str:
    """Whisper-large-v3-turbo. Language is auto-detected per utterance."""
    opts = {"path_or_hf_repo": MODEL}
    if context:
        opts["initial_prompt"] = context
    result = mlx_whisper.transcribe(audio, **opts)
    # Language mis-detection on short/noisy segments produces foreign-language
    # garbage ("してるし" / "Estados.") — drop anything not heard as EN/IT.
    lang = result.get("language")
    if lang and lang not in ALLOWED_LANGS:
        return ""
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


_CORRECT_SYSTEM = (
    "You correct speech-to-text errors in voice dictation about software development. "
    "The dictation may be in ENGLISH or ITALIAN. The recognizer mis-hears words, especially "
    "technical terms (libraries, APIs, identifiers), proper nouns, and homophones. Replace "
    "each mis-heard word with the word MOST LIKELY actually spoken, judged by how similar "
    "they SOUND, using any known terms given. Keep the SAME language as the input. Preserve "
    "wording, meaning, length, and intent. Do NOT paraphrase, answer, translate, or comment. "
    "If already correct, return it verbatim. Output ONLY the corrected text."
)
# Few-shot pairs — these are what make the model fix the HARD phonetic mis-hearings (and NOT
# over-correct already-correct text), in BOTH languages. Verified empirically before shipping.
_CORRECT_SHOTS = (
    ("Known terms: Stripe\nTranscription: replace the fake strap test",
     "replace the fake Stripe test"),
    ("Transcription: I need to right the off indication module",
     "I need to write the authentication module"),
    ("Transcription: puoi sistemare il bag nel codice",
     "puoi sistemare il bug nel codice"),
    ("Transcription: Is there a better way to solve this?",
     "Is there a better way to solve this?"),
)


def _ensure_corrector():
    """Lazy-load the correction LLM ON the ASR thread so it shares the MLX Metal
    stream with the ASR model. Cheap after the first call (model is cached)."""
    global CORRECTOR, _CORRECT_SAMPLER
    if CORRECTOR is None:
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler
        CORRECTOR = load(CORRECT_MODEL_ID)
        _CORRECT_SAMPLER = make_sampler(temp=0.0)   # deterministic — no creative rewriting


def correct_text(raw: str) -> str:
    """Fix ASR mis-transcriptions with the local LLM (runs on the ASR thread). Falls
    back to the raw text on any anomaly, so correction can never make things worse."""
    if not raw or not raw.strip():
        return raw
    from mlx_lm import generate
    _ensure_corrector()
    model, tok = CORRECTOR
    msgs = [{"role": "system", "content": _CORRECT_SYSTEM}]
    for u, a in _CORRECT_SHOTS:
        msgs += [{"role": "user", "content": u}, {"role": "assistant", "content": a}]
    user = (f"Known terms: {CORRECT_VOCAB}\n" if CORRECT_VOCAB else "") + f"Transcription: {raw}"
    msgs.append({"role": "user", "content": user})
    prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
    # Cap generation to ~4 tokens/word so it can't run off into a paraphrase or answer.
    cap = min(200, max(32, len(raw.split()) * 4 + 16))
    out = generate(model, tok, prompt=prompt, max_tokens=cap,
                   sampler=_CORRECT_SAMPLER, verbose=False).strip()
    # Safety net: empty or wildly-longer output means the model misbehaved — keep raw.
    if not out or len(out) > len(raw) * 2 + 40:
        return raw
    # Anti-hallucination gate: a correction should FIX words, not invent a new sentence.
    # If fewer than half the output words were present in the raw input, the model
    # rewrote/hallucinated (e.g. "command stop" -> "you can use a workflow") — keep raw.
    raw_words = set(raw.lower().split())
    out_words = out.lower().split()
    if out_words:
        kept = sum(1 for w in out_words if w in raw_words)
        if kept / len(out_words) < 0.5:
            return raw
    return out


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
    return web.json_response({"sessions": await discover_claude_sessions()})


# Self-test phrases for the in-app "Command self-test". The expected result is COMPUTED
# from the real interpreter (net line) so it can never drift from the grammar. Each is
# line-verifiable (a typing result), covering single / region / nested / concatenated
# commands and the editing verbs (backspace, backword, delete, replace) + interrogative.
COMMAND_TEST_PHRASES = [
    ("command slash", "single command"),
    ("command caps start deploy caps stop", "CAPS mode block"),
    ("command number start one two three number stop", "NUMBER mode block"),
    ("command start slash dot dash command stop", "region: 3 concatenated commands"),
    ("command caps start spell start a b c spell stop caps stop", "nested CAPS over SPELL"),
    ("test command start backspace two times command stop", "type, then BACKSPACE x2"),
    ("alpha beta command start backword one command stop", "type, then BACKWORD one word"),
    ("hello world command delete start world delete stop", "type, then DELETE a word"),
    ("git status command replace start status replace with commit replace stop",
     "type, then REPLACE a word"),
    ("hello command question mark", "interrogative: ends with ?"),
    ("command start number start four five number stop caps start hi caps stop command stop",
     "region: NUMBER then CAPS concatenated"),
    ("command number start four five number stop caps start hi caps stop",
     "one argument: only NUMBER is a command, the rest is literal"),
    # ── real-world dictation: URLs, code, markdown ──
    ("https command colon command slash command slash github command dot com",
     "URL: https://github.com"),
    ("command open quotes hello world command close quotes", "double-quoted string"),
    ("command open parentheses foo command close parentheses", "parentheses"),
    ("command backtick npm install command backtick", "inline code (backticks)"),
    ("command triple backticks", "triple backticks (code fence open)"),
    ("command code block python", "fenced code block with language"),
    ("command hash", "hash / pound sign"),
    ("command heading two introduction", "markdown H2 heading"),
    ("command bullet first item", "markdown bullet"),
    ("command bold important", "markdown bold"),
    ("command numbered item buy milk", "numbered list item"),
    ("command quote block note", "markdown blockquote"),
    ("command start pipe ampersand percent command stop", "region of raw symbols"),
    # ── nested lists (auto-indent + auto-numbering) ──
    ("command bullet start alpha command enter beta command enter gamma command enter bullet stop",
     "bulleted list, 3 rows"),
    ("command bullet start a command enter b command enter bullet start c command enter d "
     "command enter bullet stop e command enter bullet stop",
     "bulleted list with an indented sub-list"),
    ("command bulletnum start a command enter b command enter bulletnum start c command enter d "
     "command enter bulletnum stop e command enter bulletnum stop",
     "numbered list with nested numbering (2.1, 2.2)"),
]


async def handle_test_suite(request):
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    phrases = []
    for phrase, note in COMMAND_TEST_PHRASES:
        m: dict = {}
        interpret(phrase, m, prefix_mode=True)   # the NET line is the expected result
        phrases.append({"phrase": phrase, "expect": m.get("line", ""), "note": note})
    print(f"[test-suite] served {len(phrases)} phrases", file=sys.stderr)
    return web.json_response({"phrases": phrases})


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


async def handle_focus(request):
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    try:
        data = await request.json()
    except Exception:  # noqa: BLE001
        return web.json_response({"error": "invalid JSON"}, status=400)
    target = data.get("session", "")
    if not isinstance(target, str) or not target:
        return web.json_response({"error": "session required"}, status=400)
    ok, err = await _focus_target(target)
    if not ok:
        return web.json_response({"error": err}, status=500)
    return web.json_response({"ok": True})


# --------------------------------------------------------------------------- #
# WebSocket audio stream
# --------------------------------------------------------------------------- #
_LINE_KEYS = ("line", "undo", "redo", "edit_mode", "edit_target", "edit_repl",
              "case_mode", "spelling", "sym_mode", "num_region", "scope_stack",
              "armed_prefix_erase")


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
    m["armed_prefix_erase"] = 0   # a submitted line drops any provisional-"command" arm


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
    # `session` is now a kind-prefixed target from /sessions discovery
    # ('tmux:…', 'iterm:…', 'terminal:…'); a bare value is treated as tmux.
    session = str(cfg.get("session", ""))
    # dry_run = self-test mode: transcribe + interpret but DON'T inject anywhere (and
    # skip the target check, since there's no real Claude session behind it).
    dry_run = bool(cfg.get("dry_run"))
    if not dry_run and not await target_exists(session):
        await ws.send_json({"type": "error", "error": "unknown session"})
        await ws.close()
        return ws

    context = str(cfg.get("context") or "")   # explicit app override; else chosen below by mode
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
    # prefix_mode = literal-by-default; commands need the "command" prefix (see voice_commands).
    prefix_mode = bool(cfg.get("prefix_mode"))
    # In prefix mode, bias Whisper toward the command vocabulary (unless the app sent an
    # explicit context). This is what stops "start" → "third" and "command" → "come and".
    if not context:
        context = COMMAND_CONTEXT if prefix_mode else DEFAULT_CONTEXT
    # correct = run the local LLM correction pass over each transcription before inject.
    correct = bool(cfg.get("correct", CORRECT_ENABLED))

    seg = UtteranceSegmenter(sample_rate=sample_rate, silence_hold_sec=silence_hold)
    modes: dict = {}  # persistent caps/spell + editable-line state for this connection
    await ws.send_json({"type": "ready", "session": session, "sample_rate": sample_rate})
    await ws.send_json({"type": "cheatsheet", "groups": cheatsheet()})
    print(f"[stream] connected -> session={session!r} sr={sample_rate} "
          f"hold={silence_hold}s auto_send={auto_send} prefix_mode={prefix_mode} "
          f"correct={correct} biased={bool(context)}", file=sys.stderr)

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
                    if text and correct:
                        # Fix ASR mis-transcriptions before command interpretation +
                        # injection. Best-effort: on failure keep the raw text.
                        raw_text = text
                        try:
                            text = await loop.run_in_executor(ASR_EXECUTOR, correct_text, text)
                        except Exception as e:  # noqa: BLE001
                            print(f"[stream] correction failed (using raw): {e}", file=sys.stderr)
                        if text != raw_text:
                            print(f"[stream] corrected: {raw_text!r} -> {text!r}", file=sys.stderr)
                    if text:
                        before = _snapshot_modes(modes)   # for change-detect + rollback
                        actions = interpret(text, modes, prefix_mode=prefix_mode)
                        if auto_send and not (actions and actions[-1] == ("key", "Enter")):
                            actions = actions + [("key", "Enter")]
                            _reset_line(modes)            # auto-submitted -> no longer editable
                        if dry_run:
                            ok, err = True, None          # self-test: never touch a real session
                        else:
                            ok, err = await execute_actions(session, actions)
                            if not ok:
                                _restore_modes(modes, before)  # C7: revert the optimistic edit
                        await ws.send_json(
                            {"type": "final", "text": text, "rendered": render(actions),
                             "line": modes.get("line", ""), "injected": ok}
                            | ({} if ok else {"error": err})
                        )
                        now = (bool(modes.get("spelling")), modes.get("case_mode", "none"),
                               modes.get("edit_mode"),
                               bool(modes.get("sym_mode")) or bool(modes.get("num_region")))
                        was = (bool(before["spelling"]), before["case_mode"], before["edit_mode"],
                               bool(before.get("sym_mode")) or bool(before.get("num_region")))
                        if now != was:
                            await ws.send_json({"type": "mode", "spell": now[0], "caps": now[1],
                                                "edit": now[2], "symbols": now[3]})
                        print(f"[stream] -> {session}: {text!r} => {render(actions)!r} ok={ok}",
                              file=sys.stderr)
                    else:
                        await ws.send_json({"type": "final", "text": ""})
            elif msg.type == WSMsgType.TEXT:
                # Live reconfiguration — switch the target Claude or toggle prefix mode
                # WITHOUT reconnecting (instant; no slow WS re-handshake + re-validate).
                try:
                    upd = json.loads(msg.data)
                except Exception:  # noqa: BLE001
                    continue
                if upd.get("type") == "config":
                    if "session" in upd:
                        new_sess = str(upd["session"])
                        if await target_exists(new_sess):
                            session = new_sess
                            _reset_line(modes)     # new target — drop the old editable line
                            await ws.send_json({"type": "retargeted", "session": session})
                        else:
                            await ws.send_json({"type": "error", "error": "unknown session"})
                    if "prefix_mode" in upd:
                        prefix_mode = bool(upd["prefix_mode"])
                    if "auto_send" in upd:
                        auto_send = bool(upd["auto_send"])
                    if "correct" in upd:
                        correct = bool(upd["correct"])
                    print(f"[stream] reconfigured -> session={session!r} "
                          f"prefix_mode={prefix_mode} auto_send={auto_send} correct={correct}",
                          file=sys.stderr)
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
            web.get("/test-suite", handle_test_suite),
            web.get("/pane", handle_pane),
            web.post("/say", handle_say),
            web.post("/focus", handle_focus),
            web.get("/stream", handle_stream),
        ]
    )
    return app


def main():
    global TOKEN, TMUX, MODEL, BACKEND, CORRECT_ENABLED, CORRECT_MODEL_ID, CORRECT_VOCAB

    parser = argparse.ArgumentParser(description="Talk to Claude v2 voice server")
    parser.add_argument("--host", default=None, help="Bind address (default: Tailscale IP)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("CLAUDE_VOICE_PORT", "8765")))
    parser.add_argument("--token", default=os.environ.get("CLAUDE_VOICE_TOKEN", DEFAULT_TOKEN))
    parser.add_argument("--tmux", default=os.environ.get("TMUX_BIN", "tmux"))
    parser.add_argument("--backend", choices=("parakeet", "whisper"),
                        default=os.environ.get("CLAUDE_VOICE_BACKEND", DEFAULT_BACKEND),
                        help="ASR backend (default: parakeet — EU langs incl. IT, near-zero hallucinations)")
    parser.add_argument("--model", default="", help="Model id; defaults to the backend's model")
    parser.add_argument("--correct", action=argparse.BooleanOptionalAction, default=CORRECT_ENABLED,
                        help="LLM correction of ASR output before inject (--no-correct to disable)")
    parser.add_argument("--correct-model", default=CORRECT_MODEL_ID, help="mlx-lm model for correction")
    parser.add_argument("--correct-vocab", default=os.environ.get("CLAUDE_VOICE_VOCAB", ""),
                        help="Known terms hint for correction, e.g. 'Stripe, tmux, MLX'")
    args = parser.parse_args()

    TOKEN = args.token
    TMUX = args.tmux
    BACKEND = args.backend
    MODEL = args.model or (PARAKEET_MODEL_ID if BACKEND == "parakeet" else WHISPER_MODEL_ID)
    CORRECT_ENABLED = args.correct
    CORRECT_MODEL_ID = args.correct_model
    CORRECT_VOCAB = args.correct_vocab

    host = args.host or detect_tailscale_ip()
    no_tailscale = host is None
    if no_tailscale:
        # No Tailscale IP and no explicit --host: bind LOOPBACK only — never the
        # LAN/world with just the shared token. Pass --host <ip> to expose it.
        host = "127.0.0.1"

    print(f"Loading {BACKEND} model {MODEL} (one-time)…", file=sys.stderr)
    t0 = time.time()
    # Load on the dedicated ASR thread so the model + all inference share one
    # MLX Metal stream.
    ASR_EXECUTOR.submit(_load_model, BACKEND, MODEL).result()
    print(f"Model ready in {time.time() - t0:.1f}s", file=sys.stderr)
    if CORRECT_ENABLED:
        print(f"Loading correction model {CORRECT_MODEL_ID} (one-time)…", file=sys.stderr)
        t0 = time.time()
        ASR_EXECUTOR.submit(_ensure_corrector).result()   # preload on the ASR thread
        print(f"Corrector ready in {time.time() - t0:.1f}s", file=sys.stderr)

    print("─" * 64)
    print(" Talk to Claude — v2 voice server")
    print(f"   Listening on : http://{host}:{args.port}   (ws://{host}:{args.port}/stream)")
    print(f"   Token        : {TOKEN}")
    print(f"   Backend      : {BACKEND}")
    print(f"   Model        : {MODEL}")
    print(f"   Correction   : {CORRECT_MODEL_ID if CORRECT_ENABLED else 'off'}")
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
