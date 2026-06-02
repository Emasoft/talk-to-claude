# Talk to Claude — v2 architecture (audio streamed to Mac, transcribed on Mac)

Decision record for the streaming + local-MLX redesign. Raw per-repo research
notes live in `docs_dev/research/` (gitignored). This file is the durable
summary.

## Goal

Talk continuously to a `claude` session from an iPhone/iPad over Tailscale.
Audio is **streamed from the phone to the Mac** and **transcribed on the Mac**
with a local MLX model. **Continuous auto-recognition — no push-to-talk.**

## Engine decision: Whisper-large-v3-turbo (MLX)

**Pivoted from Qwen3-ASR after on-hardware testing.** The research favored
Qwen3-ASR-0.6B and it's flawless on English — but it badly mangles **Italian**
(both 0.6B and 1.7B, even with a `language='it'` hint), a dealbreaker since the
user mixes Italian and English. `mlx-whisper` running
`mlx-community/whisper-large-v3-turbo` transcribes both languages accurately,
auto-detects language per utterance, and runs at the **same speed** (RTF ~0.16 on
M4 Pro, ~0.9 s for a 5 s utterance). It fits the VAD-segment-then-batch design
perfectly. Original Qwen3 research kept below for context.

Surveyed ~35 Apple-Silicon ASR projects (Parakeet, Whisper-MLX, Qwen3-ASR,
SenseVoice, GigaAM, plus live-dictation apps and ready servers). Initial winner:
**`moona3k/mlx-qwen3-asr`** (PyPI `mlx-qwen3-asr`, Apache-2.0) running
`Qwen/Qwen3-ASR-0.6B`:

- 30 languages (incl. Italian + English), small + fast on Apple Silicon.
- Reported to beat Whisper-large-v3 at ~⅓ the size.
- Clean Python API (`Session`, `transcribe`, streaming module).

Runner-ups: Parakeet-TDT-0.6b-v3 (leanest/fastest, English+European),
Whisper-large-v3-turbo (broadest languages, heavier).

## Key measurement that shaped the design (M4 Pro, 64 GB)

| Mode | Result | Accuracy |
|---|---|---|
| **Batch** `transcribe()` of a whole utterance | 0.67–0.98 s for 5.6 s audio (RTF ~0.15) | **flawless** |
| Chunk-streaming (1 s chunks) | ~0.2 s/chunk | **degraded** ("Hello Claude…" → "Hello, clouds. Please list…") |

Conclusion: **don't chunk-stream the ASR.** Segment utterances with a VAD and
run one **batch** transcription per utterance. `init_streaming` is free and the
model loads in ~2 s and stays resident.

## Architecture

```
iPhone / iPad (SwiftUI)                         Mac mini (MLX, Tailscale)
 AVAudioEngine tap → AVAudioConverter           WebSocket /stream  (aiohttp)
   → 16 kHz mono PCM16                ──WS bin──▶  energy VAD segments utterances
 continuous, NO push-to-talk          (encrypted) (300 ms pre-roll, ~0.7 s
 live "listening"/level                            silence gate, no push-to-talk)
 final text + Claude pane  ◀──JSON───            → batch Qwen3-ASR per utterance
                                                  → tmux send-keys → claude
```

- **ASR runs on one dedicated thread** (`ThreadPoolExecutor(max_workers=1)`):
  MLX/Metal is thread-bound — the model is loaded on that thread and every
  transcription runs there, or MLX raises
  `There is no Stream(gpu, 1) in current thread`. One worker also serializes
  inference and keeps the asyncio loop unblocked.
- **Latency:** finish a sentence → ~0.7 s silence gate detects the end →
  ~0.7–1 s transcription → text lands in Claude (~1.5 s total).
- A `context` hint biases the ASR toward terminal/coding vocabulary.

## WebSocket protocol (`/stream`)

1. Client → server: one TEXT frame `{"token","session","context"?,"sample_rate"?}`.
2. Server → client: `{"type":"ready",...}` or `{"type":"error",...}`.
3. Client → server: binary frames = little-endian PCM16 mono @ `sample_rate`.
4. Server → client events: `{"type":"speech_start"}`,
   `{"type":"final","text":"...","injected":true}`, `{"type":"error",...}`.

## Server endpoints

| Route | Auth | Purpose |
|---|---|---|
| `GET /health` | no | reachability probe |
| `GET /sessions` | yes | list tmux sessions |
| `GET /pane?session=&lines=` | yes | tail a tmux pane (show Claude's output) |
| `POST /say {session,text}` | yes | text injection (the v1 app uses this) |
| `WS /stream` | yes | the voice path |

The v2 server is a **superset of v1**: the v1 on-device-STT app talks to `/say`,
so it works against this server unchanged; the v2 streaming client uses `/stream`.

## Files

- `server/voice_server.py` — the v2 server (aiohttp + Qwen3-ASR + tmux).
- `pyproject.toml` — uv project (`mlx-qwen3-asr`, `aiohttp`, `numpy`).
- `server/run.sh` — `uv run` launcher (auto-detects Tailscale IP).
- `ios/` — iOS app. v1 = on-device STT (installable now). v2 = streaming client (TODO).

## Status

- [x] Engine de-risked on real hardware (Qwen3-ASR-0.6B, accurate, fast).
- [x] v2 server built + verified end-to-end (WS audio → VAD → ASR → tmux inject).
- [ ] v2 iOS streaming client (AVAudioEngine → PCM16 → WebSocket).
- [ ] On-device validation (needs the iPad paired via USB once).
