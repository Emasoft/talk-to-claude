# CLAUDE.md — TalkToClaude

Hands-free voice dictation to `claude` CLI sessions. An **iOS app** (iPhone/iPad)
streams mic audio over Tailscale to a **Mac Python server** that transcribes with
a local Whisper model and injects the text into the target terminal/Claude tab.

```
iPhone/iPad (SwiftUI)  ──WebSocket(PCM16 16kHz)──►  Mac server (aiohttp + mlx_whisper)
   pick a Claude, talk                                  transcribe → interpret → inject
                                                         into the chosen iTerm/tmux tab
```

## Layout

| Path | What |
|---|---|
| `server/voice_server.py` | aiohttp server: `/health` `/sessions` `/pane` `/say` `/focus` `/stream`(WS). ASR, Claude discovery, iTerm/tmux injection, focus. |
| `server/voice_commands.py` | The verbal-command **interpreter** (`interpret()`), bilingual EN/IT. Default mode = command-by-default; **prefix mode** = literal-by-default scope-stack grammar (below). |
| `server/test_voice_commands.py` | Interpreter tests. Run: `cd server && python3 test_voice_commands.py` (expect "All green"). |
| `ios/TalkToClaude/*.swift` | The app. `ContentView` (main UI + flux shader + cheat-sheet chips + session sidebar), `SettingsView`, `PrefixGrammarHelpView` (in-app grammar help), `VoiceStream` (WS+audio), `ClaudeClient` (HTTP), `AppSettings`. |
| `ios/project.rb` | **Generates** `TalkToClaude.xcodeproj` by globbing `*.swift`. The `.xcodeproj` is a build artifact — never hand-edit it. |

## Run / build / verify

```bash
# Mac server (binds your Mac's TAILSCALE IP, NOT localhost — e.g. 100.99.233.43:8765)
uv run --project . python server/voice_server.py
curl -s http://<tailscale-ip>:8765/health          # -> {"ok": true}   (localhost will NOT answer)

# After editing any server/*.py, RESTART the server (interpreter is imported at startup).

# Interpreter tests
cd server && python3 test_voice_commands.py

# iOS: regenerate the project after ADDING/REMOVING a .swift file, then build
ruby ios/project.rb
xcodebuild -project ios/TalkToClaude.xcodeproj -scheme TalkToClaude \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Gotchas:
- The server binds the **Tailscale IP**, so `curl localhost:8765` returns nothing — always use the Tailscale IP.
- After installing a new build to the device, iOS may keep the OLD instance running — **force-quit and reopen** the app, or you're testing stale code.
- Injection uses the **iTerm2 Python API** (`iterm2` pip pkg), NOT AppleScript — the iTerm/Terminal AppleScript bridge times out (-1712) on this machine.
- The bearer token currently committed in tests is **public — rotate it** (it's the `Authorization: Bearer …` shared secret).
- No absolute dev paths in committed code (IRON). Procedural Metal shader only for the background — no bitmap.

## Prefix-mode voice grammar (THE rules — keep server + `PrefixGrammarHelpView` in sync)

Prefix mode is opt-in (`Settings → Voice → Require "command" prefix`, sent live over
the open socket — no reconnect). When ON, **everything is typed literally** and a
command fires only after the word **`command`** (`comando`). The grammar is a
**nested scope stack** where `START` = `(` and `STOP` = `)`.

**Two ways to invoke commands — they differ in how many arguments they take:**

1. **Sugar (ONE argument)** — `command` WITHOUT explicit `start`/`stop`:
   - `command <cmd>` → fires exactly one command, then back to literal.
     `command enter` → ⏎ · `command slash` → / · `command arrow up` → ↑ · `command space` → ␣
   - `command <MODE> start … <MODE> stop` → one self-contained mode block (no `command`
     inside; the closing `<MODE> stop` needs no `command`). Modes nest — still ONE argument:
     `command number start four five number stop` → `45`
     `command caps start deploy now caps stop` → `DEPLOY NOW`
     `command spell start al em er spell stop` → `lmr`
     `command caps start spell start al em er spell stop caps stop` → `LMR`  (CAPS wraps SPELL)
     `command delete start world delete stop` → erases "world" from the line
     `command replace start cat replace with dog replace stop` → cat → dog

2. **Full region (MANY arguments)** — `command start … command stop` holds as many
   commands/blocks as you like, and they concatenate:
   `command start number start one number stop caps start spell start al em er spell stop caps stop command stop` → `1LMR`
   - `<N> times` repeats a command — **region only**: `command start backspace twelve times command stop` → ⌫×12
   - `backword <N>` deletes N whole words: `command start backword two command stop`

**The rule:** every `START` pushes a scope; every `STOP` pops the **innermost** open
one (LIFO). Inside an open scope a nested `<MODE> start` needs no `command`. A bare
`stop` with nothing open is just the literal word "stop".

MODES: `caps` (uppercase modifier) · `spell` (letters) · `number` (digits) ·
`delete` · `replace`. Italian: `comando inizio fine maiuscolo compita numero
cancella sostituzione`.

**Implementation** (`voice_commands.py`): a `stack` of frames — `cmd` (a region, many
args), `once` (a single-arg sugar command, auto-pops when its one block completes),
and the mode tags. `caps` is an ambient MODIFIER that nests over a content mode;
`spell/number/delete/replace` decide what a content word becomes. Frame state persists
across utterances via `modes["scope_stack"]` (+ the flat `case_mode/spelling/num_region/
edit_mode` mirrors), snapshotted in the server's `_LINE_KEYS` for injection rollback.

> NOT the same as default mode (prefix OFF): there commands convert automatically
> (command-by-default) with independent `caps`/`spell` toggles, no scope stack.

When you change this grammar: edit `voice_commands.py`, add/adjust cases in
`test_voice_commands.py` until green, restart the server, AND update
`ios/TalkToClaude/PrefixGrammarHelpView.swift` so the in-app help still matches.
