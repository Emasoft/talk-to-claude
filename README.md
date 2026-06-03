# Talk to Claude

Speak to a running `claude` session from your iPhone/iPad over Tailscale,
hands-free and continuously.

Your iPhone streams raw microphone audio to your Mac, which segments speech with
an energy VAD, transcribes each finished sentence locally with **Whisper**
(mlx), turns spoken commands into keystrokes, and injects them into a `claude`
CLI session running in **tmux**. Nothing leaves your Tailscale network.

```
 iPhone (SwiftUI)                          Mac
 ┌──────────────────────────┐              ┌───────────────────────────────────┐
 │ mic ▸ PCM16 @16kHz        │  audio (WS)  │ voice_server.py                   │
 │ cheat-sheet of commands   │ ──Tailscale─▶│  energy VAD ▸ Whisper (mlx)       │
 │ live transcript           │ ◀──events────│  voice_commands.py (interpreter)  │
 │ EN / IT toggle            │  WireGuard   │   └─ tmux send-keys ─▶ claude     │
 └──────────────────────────┘              └───────────────────────────────────┘
        100.68.40.29                                   100.99.233.43
```

## What's in here

| Path | What it is |
|------|------------|
| `ios/TalkToClaude/` | SwiftUI app sources |
| `ios/project.rb` | Generates `TalkToClaude.xcodeproj` (uses the `xcodeproj` gem) |
| `server/voice_server.py` | Mac receiver — WebSocket audio in, VAD + Whisper, tmux inject |
| `server/voice_commands.py` | Bilingual (EN/IT) verbal-command interpreter + unit tests target |
| `server/test_voice_commands.py` | `python test_voice_commands.py` — interpreter tests |
| `server/run.sh` | Convenience launcher (uses `uv`) |

## 1. Start the Mac receiver

You need a `claude` CLI running inside a tmux session (e.g. `default`).

```bash
cd ~/Code/IOSVoice/server
./run.sh
```

It auto-detects your Tailscale IP, binds only to it, loads Whisper once, and
prints the IP / port / token to type into the app. Without a Tailscale IP it
binds **loopback only** (`127.0.0.1`); pass `--host <ip>` to expose it on a
trusted network.

```bash
./run.sh --port 9000 --token my-own-secret     # flags
CLAUDE_VOICE_TOKEN=my-own-secret ./run.sh       # env
./run.sh --host 100.99.233.43                   # force the bind IP
./run.sh --model mlx-community/whisper-large-v3-turbo
```

To keep it running after you log out, launch it under tmux:
`tmux new -d -s claude-voice '~/Code/IOSVoice/server/run.sh'`.

## 2. Build & run the iOS app

```bash
cd ~/Code/IOSVoice
ruby ios/project.rb          # generates ios/TalkToClaude.xcodeproj
open ios/TalkToClaude.xcodeproj
```

In Xcode: pick the **TalkToClaude** target ▸ **Signing & Capabilities** ▸ your
**Team**, plug in your device, **Run** (⌘R). First launch asks for **Microphone**
permission — allow it.

The defaults (`100.99.233.43`, port `8765`, the baked token) match the server,
so it connects out of the box. Tap the gear to change the Mac IP / port / token /
target session, the **pause threshold**, and **auto-send**.

## 3. Use it

- Tap the **mic** and talk normally. When you pause (~0.7 s, adjustable in
  Settings) the sentence is transcribed and its keystrokes are typed into Claude.
- By default the prompt is **submitted only when you say "invio" / "enter"** so
  you can compose across pauses. Turn on **Auto-send** to submit every sentence.
- Speech gives words, not symbols, so a **cheat sheet of verbal commands** fills
  the screen: `slash` → `/`, `open parentheses` → `(`, `new line` → ⇧⏎, headings,
  code fences, etc. Tap **EN/IT** to switch the command language.
- **Modes** (shown as badges): `start caps mode` … `stop caps mode`,
  `start spell mode` (dictate letter-by-letter), and edit the un-submitted line
  with `start delete mode <words> stop delete mode` /
  `start replace mode <find> replace with <new> stop replace mode`, plus
  `undo` / `redo`. Editing works until you press Enter.

## Security

- The server binds to the **Tailscale** interface (or loopback if none), so it
  isn't on your LAN or the internet.
- Every endpoint except `/health` requires the bearer **token**. **Change the
  baked default** — `mMfRuOWn9rGWskJOnI4HkrTwReVtblyg` is committed to this repo
  and therefore public. Set a new value in both the app (Settings ▸ Token) and
  the server (`--token` / `CLAUDE_VOICE_TOKEN`).
- HTTP is plaintext but Tailscale (WireGuard) encrypts the whole path. Text is
  injected with `tmux send-keys -l --` + an argv array, so it can't be
  interpreted as shell or tmux commands.

## Notes / limits

- Transcription is **batch-per-utterance** (one Whisper pass when you stop
  talking) — more accurate than chunk-streaming, lands ~1 s after you pause.
- Language is **auto-detected per utterance** (English / Italian / …).
- **Foreground only**: keep the app open while talking (the screen stays awake).
  Backgrounding stops capture and restores other apps' audio.
- Targets the **CLI in tmux** — not the Claude Desktop app.
- Run the interpreter tests with `cd server && uv run python test_voice_commands.py`.
