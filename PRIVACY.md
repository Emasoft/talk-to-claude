# Privacy Policy — Talk to Claude

_Last updated: 2026-06-04_

**Talk to Claude** ("the app") is a companion app that streams your voice from
your iPhone or iPad to a server **you run yourself** on **your own Mac**, over
**your own private Tailscale network**. This policy explains exactly what the
app does and does not do with your data.

## The short version

- **We collect nothing.** The developer has no servers, no analytics, no
  accounts, and receives none of your data.
- **Your voice never leaves your own network.** Microphone audio goes only to
  the Mac you set up, over a WireGuard‑encrypted Tailscale link.
- **Transcription happens on your Mac**, locally, using OpenAI Whisper. No
  cloud transcription service is used.

## What the app accesses

| Capability | Why | Where it goes |
|------------|-----|---------------|
| **Microphone** | To capture the speech you choose to dictate | Streamed to your own Mac only |
| **Local / Tailscale network** | To reach the companion server on your Mac | Your private network only |

The app asks for microphone permission (iOS `NSMicrophoneUsageDescription`) and
local‑network permission (`NSLocalNetworkUsageDescription`) the first time it
needs them. You can revoke either at any time in **iOS Settings → Talk to Claude**.

## What we do **not** do

- We do **not** collect, store, sell, or share any personal data.
- We do **not** use analytics, advertising, tracking, or third‑party SDKs.
- We do **not** require an account or any sign‑in.
- We do **not** record or retain your audio. Audio is streamed in real time to
  your Mac for transcription and is not persisted by the app.
- We do **not** transmit your voice or transcripts to the developer or to any
  third‑party service. The only destination is the server **you** configure.

## Where your data actually goes

1. You speak into your iPhone/iPad.
2. The app streams raw audio over your Tailscale (WireGuard‑encrypted) network
   to the companion server running on your Mac.
3. Your Mac transcribes the audio locally with Whisper and types the result into
   your own `claude` CLI session.

Every step happens on hardware **you** own and a network **you** control. What
your Mac and the `claude` CLI do with the resulting text is governed by **your**
own setup and by Anthropic's terms for the Claude CLI — outside the scope of
this app.

## Children's privacy

The app is rated 4+ and collects no data from anyone, including children.

## Changes to this policy

If this policy changes, the updated version will be published at the same URL
with a new "Last updated" date.

## Contact

Questions about this policy: open an issue on the project's public repository, or
contact the developer (Gaetano Sabetta / Emasoft) at the address listed on the
App Store support page.
