# Talk to Claude

Speak to a running `claude` session from your iPhone/iPad over Tailscale.

Your voice is transcribed **on-device** (Apple Speech, nothing leaves the
phone), and each finished sentence is delivered to a `claude` CLI session
running in **tmux** on your Mac. Optionally, the app shows Claude's terminal
output back on your phone.

```
 iPhone (SwiftUI)                         Mac (mac-mini-di-emanuele)
 ┌─────────────────────────┐             ┌──────────────────────────────┐
 │ mic ▸ on-device STT     │  utterance  │ claude_voice_server.py        │
 │ live transcript         │ ──HTTP────▶ │  POST /say                    │
 │ auto-send on pause      │  (Tailscale │   └─ tmux send-keys ─▶ claude │
 │ shows pane (optional)   │ ◀──pane──── │  GET  /pane / /sessions       │
 └─────────────────────────┘  WireGuard) └──────────────────────────────┘
        100.68.40.29                                100.99.233.43
```

## What's in here

| Path | What it is |
|------|------------|
| `ios/TalkToClaude/` | SwiftUI app sources |
| `ios/project.rb` | Generates `TalkToClaude.xcodeproj` (uses the `xcodeproj` gem) |
| `server/claude_voice_server.py` | Mac receiver — stdlib only, injects into tmux |
| `server/run.sh` | Convenience launcher |

## 1. Start the Mac receiver

You need a `claude` CLI running inside a tmux session (you already have several,
e.g. `default`, `alexandre`).

```bash
cd ~/Code/IOSVoice/server
./run.sh
```

It auto-detects your Tailscale IP (`100.99.233.43`), binds only to it, and
prints the IP / port / token to type into the app:

```
 Listening on : http://100.99.233.43:8765
 Token        : mMfRuOWn9rGWskJOnI4HkrTwReVtblyg
 tmux sessions: default, alexandre, ...
```

Override anything via flags or env:

```bash
./run.sh --port 9000 --token my-own-secret           # flags
CLAUDE_VOICE_TOKEN=my-own-secret ./run.sh             # env
./run.sh --host 100.99.233.43                         # force the bind IP
```

To keep it running after you log out, launch it under tmux too:
`tmux new -d -s claude-voice '~/Code/IOSVoice/server/run.sh'`.

## 2. Build & run the iOS app

```bash
cd ~/Code/IOSVoice
ruby ios/project.rb          # generates ios/TalkToClaude.xcodeproj
open ios/TalkToClaude.xcodeproj
```

In Xcode:

1. Select the **TalkToClaude** target ▸ **Signing & Capabilities** ▸ choose your
   **Team** (a free Apple ID works for personal device installs). Change the
   Bundle Identifier if Xcode complains it's taken.
2. Plug in your iPhone (or pick it from the device menu) and press **Run** (⌘R).
3. First launch asks for **Microphone** and **Speech Recognition** permission —
   allow both.

The defaults (`100.99.233.43`, port `8765`, the baked token) match the server,
so it should connect out of the box. Tap the gear to change the Mac IP, port,
token, or target tmux session, and to toggle auto-send / the output view.

## 3. Use it

- Tap the **mic**. Talk normally. The live transcript appears as you speak.
- When you pause (~1.2 s, adjustable), the sentence is sent to Claude
  automatically. Keep talking for the next one — it's continuous.
- Prefer manual control? Settings ▸ turn off **Auto-send on pause** and use the
  **Send** button (push-to-talk style).
- With **Show Claude's output** on, the bottom pane mirrors the tmux session so
  you can read replies on the phone.

## Security

- The server binds **only** to the Tailscale interface, so it isn't exposed on
  your LAN or the internet.
- Every endpoint except `/health` requires the bearer **token**. Injecting
  keystrokes into a terminal is powerful — keep the token private and change it
  from the baked default if you like (set it in both the app and the server).
- HTTP is plaintext, but Tailscale (WireGuard) encrypts the whole path. Utterance
  text is injected with `tmux send-keys -l --` + an argv array, so it can't be
  interpreted as shell or tmux commands.

## Notes / limits

- On-device recognition is currently pinned to **en-US**. Change the locale in
  `SpeechRecognizer.swift` for another language.
- Foreground use: keep the app open while talking (the screen is kept awake).
  Background/lock-screen capture would need an audio background mode — not
  enabled in this MVP.
- Targets the **CLI in tmux**. Driving the Claude **Desktop** app instead would
  mean scripting it via macOS Accessibility — not built here.
