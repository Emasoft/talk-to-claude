#!/usr/bin/env bash
#
# Talk to Claude — one-line Mac installer for the speech-recognition (ASR) server.
#
#   curl -fsSL https://raw.githubusercontent.com/Emasoft/talk-to-claude/main/install.sh | bash
#
# Fully automated and idempotent — re-running just updates things. It installs
# Homebrew, uv, tmux, ffmpeg and the Hugging Face CLI (only the ones missing),
# downloads the MIT-licensed Whisper speech model, sets up the Python environment,
# and registers a background service that starts at login and survives reboots.
#
# Everything it installs is free and open source. macOS 15 (Sequoia) or newer.
set -euo pipefail

REPO_URL="https://github.com/Emasoft/talk-to-claude"
DEFAULT_DIR="$HOME/talk-to-claude"
WHISPER_MODEL="mlx-community/whisper-large-v3-turbo"   # OpenAI Whisper, MIT, free

# ── pretty output ────────────────────────────────────────────────────────────
if [ -t 1 ]; then C=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; Z=$'\033[0m'
else C=; G=; Y=; R=; Z=; fi
say()  { printf '\n%s▸ %s%s\n' "$C" "$*" "$Z"; }
ok()   { printf '  %s✓%s %s\n'  "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n'  "$Y" "$Z" "$*"; }
die()  { printf '\n%s✗ %s%s\n'  "$R" "$*" "$Z" >&2; exit 1; }

# ── 1. platform guard: macOS Sequoia (15) or newer ───────────────────────────
say "Checking your Mac"
[ "$(uname -s)" = "Darwin" ] || die "The Talk to Claude server runs on macOS only (for now)."
OS_VER="$(sw_vers -productVersion)"
[ "${OS_VER%%.*}" -ge 15 ] 2>/dev/null \
  || die "macOS 15 (Sequoia) or newer required — you have $OS_VER."
ok "macOS $OS_VER"
[ "$(uname -m)" = "arm64" ] || warn "Apple Silicon (M-series) is recommended; Whisper on MLX is much faster on it."

# ── 2. Homebrew ──────────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew (it may ask for your macOS password)"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# Put brew on PATH for this shell (Apple Silicon vs Intel locations).
if [ -x /opt/homebrew/bin/brew ];   then eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ];    then eval "$(/usr/local/bin/brew shellenv)"; fi
command -v brew >/dev/null 2>&1 || die "Homebrew installation failed."
ok "Homebrew ready"

# ── 3. CLI dependencies: uv, tmux, ffmpeg ────────────────────────────────────
for pkg in uv tmux ffmpeg; do
  if command -v "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    say "Installing $pkg"
    brew install "$pkg"
    ok "$pkg installed"
  fi
done

# ── 4. Hugging Face CLI (hf) — for downloading the model ─────────────────────
export PATH="$HOME/.local/bin:$PATH"   # uv installs tools here
if command -v hf >/dev/null 2>&1; then
  ok "hf (Hugging Face CLI) already installed"
else
  say "Installing the Hugging Face CLI (hf)"
  uv tool install "huggingface_hub[cli]"
  command -v hf >/dev/null 2>&1 || die "hf CLI installation failed."
  ok "hf installed"
fi

# ── 5. Get the source (works both from a clone and from 'curl | bash') ───────
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ] && [ -f "$(cd "$(dirname "$SELF")" && pwd)/server/voice_server.py" ]; then
  REPO="$(cd "$(dirname "$SELF")" && pwd)"
  ok "Using this checkout: $REPO"
else
  if [ -d "$DEFAULT_DIR/.git" ]; then
    say "Updating existing checkout at $DEFAULT_DIR"
    git -C "$DEFAULT_DIR" pull --ff-only || warn "couldn't fast-forward; keeping current checkout"
  else
    say "Downloading the source into $DEFAULT_DIR"
    git clone --depth 1 "$REPO_URL" "$DEFAULT_DIR"
  fi
  REPO="$DEFAULT_DIR"
fi

# ── 6. Python environment (Whisper-only; no Parakeet) ────────────────────────
say "Setting up the Python environment (this can take a few minutes the first time)"
( cd "$REPO" && uv sync )
ok "Python dependencies installed"

# ── 7. Whisper speech model (MIT-licensed, free; ~1.6 GB, one time) ──────────
say "Downloading the Whisper speech model — $WHISPER_MODEL (~1.6 GB, once)"
hf download "$WHISPER_MODEL" >/dev/null
ok "Whisper model ready (cached in ~/.cache/huggingface)"

# ── 8. Tailscale check (needed to reach the Mac from your iPhone/iPad) ────────
if command -v tailscale >/dev/null 2>&1 || [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  ok "Tailscale detected"
else
  warn "Tailscale not found. Install it (https://tailscale.com/download) and sign in on"
  warn "BOTH this Mac and your iPhone/iPad — the server only binds to the Tailscale network."
fi

# ── 9. Background service (starts at login, respawns on crash) ───────────────
say "Installing the background ASR service"
ASR_BACKEND=whisper "$REPO/server/asr-service.sh" install

# ── 10. Done ─────────────────────────────────────────────────────────────────
say "All set — Talk to Claude's Mac server is installed and running"
cat <<DONE

  Everything above is free and open source. Nothing leaves your network.

  Next steps:
    1. On the same Mac, start a Claude session in tmux, e.g.:
         tmux new -s default 'claude'
    2. Open the Talk to Claude app on your iPhone/iPad.
       The app's default IP / port / token already match this server, so it
       connects out of the box (the status line above shows the address).
    3. Tap the mic and talk.

  Manage the service any time:
    $REPO/server/asr-service.sh status | logs | restart | stop | uninstall

  Security: the baked default access token is public (it's in the open-source
  repo). Your traffic is already private over Tailscale's encrypted tunnel, but
  for extra safety set your own token in the app's Settings and pass a matching
  CLAUDE_VOICE_TOKEN to the server. See the README "Security" section.
DONE
