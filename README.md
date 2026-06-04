# Talk to Claude

Speak to a running `claude` session from your iPhone/iPad over Tailscale,
hands-free and continuously.

**100% free and open source (MIT).** No accounts, no fees, no in-app purchases,
no ads, no telemetry — and it always will be. The iOS app is free on the App
Store; the Mac side is this repository, which you run yourself with a one-line
installer (see [Install the ASR on your Mac](#install-the-asr-on-your-mac)).

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
| `ios/appicon.py` | Regenerates the 1024×1024 app icon (`uv run --with pillow python ios/appicon.py`) |
| `docs/APP-STORE.md` | Step-by-step App Store submission guide + ready-to-paste listing metadata |
| `PRIVACY.md` | Privacy policy (host it publicly; App Store needs the URL) |
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

## Publishing to the App Store

The app is configured for release: universal (iPhone + iPad), bundle ID
`com.emasoft.talktoclaude`, signing team `P2V8DD7FNW`, and a 1024×1024 app icon
wired into the asset catalog. The full walkthrough — App Store Connect setup,
ready-to-paste listing copy, the privacy "nutrition label" answers, archive &
upload commands, and the review-risk notes (this is a *companion* app for a Mac
server you host, which needs careful review notes) — lives in
[`docs/APP-STORE.md`](docs/APP-STORE.md). Privacy policy: [`PRIVACY.md`](PRIVACY.md).

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

## Install the ASR on your Mac

The Mac side installs with **one line** — no manual setup. Paste this into a
Terminal on a Mac running **macOS 15 (Sequoia) or newer**:

```bash
curl -fsSL https://raw.githubusercontent.com/Emasoft/talk-to-claude/main/install.sh | bash
```

It installs everything needed (Homebrew, `uv`, `ffmpeg`, the Hugging Face CLI),
downloads the **Whisper** speech model (MIT‑licensed, free), sets up a Python
environment, and registers a background service that survives reboots. At the
end it prints the IP / port / token to type into the app. It is **idempotent** —
re‑running it just updates things. To remove everything:
`server/asr-service.sh uninstall`.

Everything the installer pulls in is free and open source. You can also see this
one‑liner inside the app under **Settings → "Install the ASR for free on your
Mac."**

## Free & open source

- The app is **free on the App Store**, with **no** in‑app purchases, paid tiers,
  subscriptions, ads, or telemetry — now and always.
- The full source (iOS app + Mac server) is in this repository under the **MIT
  License** ([`LICENSE`](LICENSE)). You may use, modify, and redistribute it.
- The speech model is **OpenAI Whisper**, released under the **MIT License** — no
  fees, no usage limits, self‑hosted on your own Mac.

## Legal & disclaimers

_These apply worldwide, in every region where the app is offered._

- **No affiliation with Anthropic.** "Talk to Claude" is an independent,
  community‑built companion for the official Claude CLI. It is **not** created,
  endorsed, sponsored by, or affiliated with **Anthropic PBC**. "Claude" is a
  trademark of Anthropic; it is used here only nominatively to describe
  interoperability with the Claude CLI. All trademarks belong to their
  respective owners.
- **You bring your own Claude.** The app does not include, bundle, or provide
  access to any Claude model or API. It types text into a `claude` CLI session
  **you** already run on **your** Mac under **your** own agreement with Anthropic.
  Your use of the Claude CLI is governed by Anthropic's terms, not by this app.
- **You host the service.** Speech recognition runs on **your** Mac via the
  companion server in this repository. The developer operates no servers and
  receives none of your data. See [`PRIVACY.md`](PRIVACY.md).
- **No warranty.** The software is provided "AS IS", without warranty of any
  kind, to the fullest extent permitted by applicable law. See [`LICENSE`](LICENSE).
  Nothing here limits any non‑waivable statutory consumer rights you may have in
  your country.
- **Third‑party software.** Whisper (MIT), `mlx-whisper` (MIT), `aiohttp`
  (Apache‑2.0), `numpy` (BSD‑3‑Clause), and other dependencies remain under
  their own licenses; their copyright notices are retained.
- **Free forever.** The app and this source will remain free of charge. If that
  ever changes for new, clearly‑separate features, the version published under
  the MIT License will always remain free and open.
