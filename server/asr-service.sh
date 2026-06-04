#!/usr/bin/env bash
# Talk to Claude — ASR server service manager (macOS LaunchAgent).
#
# Installs the voice server as a per-user LaunchAgent so it starts at login,
# survives reboots, and respawns if it ever crashes (KeepAlive). Everything is
# derived from this script's own location — no machine-specific paths baked in,
# so it works from any clone.
#
#   ./asr-service.sh install     auto-start at login + start now
#   ./asr-service.sh uninstall   stop + remove auto-start
#   ./asr-service.sh start|stop|restart|status|logs
set -euo pipefail

LABEL="com.emasoft.talktoclaude.asr"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_PY="$ROOT/server/voice_server.py"
VENV_PY="$ROOT/.venv/bin/python3"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/talktoclaude-asr.log"
DOMAIN="gui/$(id -u)"
PORT="${CLAUDE_VOICE_PORT:-8765}"
# ASR backend baked into the LaunchAgent. Default whisper (MIT-licensed, free).
# The optional parakeet backend needs its extra first (uv sync --extra parakeet):
#   ASR_BACKEND=parakeet ./asr-service.sh install
BACKEND="${ASR_BACKEND:-whisper}"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Tailscale IP (same probe order the server itself uses) — for the health check.
tailscale_ip() {
  local e ip
  for e in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale; do
    ip="$("$e" ip -4 2>/dev/null | head -n1 || true)"
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
  done
  return 0
}

# Make sure the uv virtualenv exists (mirrors run.sh's `uv run`, which is how the
# server is normally launched). The LaunchAgent then execs the venv python
# directly — no dependency on `uv` being on launchd's minimal PATH.
ensure_venv() {
  command -v uv >/dev/null 2>&1 || die "uv not found on PATH — install it: https://docs.astral.sh/uv/"
  if [ ! -x "$VENV_PY" ]; then
    say "· creating virtualenv via uv…"
    ( cd "$ROOT" && uv run python -c "import sys" >/dev/null 2>&1 ) || die "uv could not create the venv"
  fi
  [ -x "$VENV_PY" ] || die "venv python still missing at $VENV_PY"
}

# Kill any hand-started server (run.sh / nohup) so the agent owns port $PORT.
# Bracket trick on the pattern so the grep/pgrep can't match its own argv.
stop_manual() {
  local pids
  pids="$(pgrep -f '[v]oice_server.py' || true)"
  if [ -n "$pids" ]; then
    say "· stopping hand-started server (pids: $pids)…"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 1
  fi
}

write_plist() {
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  # tmux + uv live in Homebrew's bin, which is NOT on launchd's default PATH;
  # ps/lsof/osascript/open are in the standard dirs; tailscale has an absolute
  # fallback inside the server. Derive the Homebrew bin from where tmux/uv live.
  local brew_bin path_value tmp
  brew_bin="$(dirname "$(command -v tmux 2>/dev/null || command -v uv)")"
  path_value="$brew_bin:/usr/bin:/bin:/usr/sbin:/sbin"
  tmp="$(mktemp)"
  cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>              <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV_PY</string>
    <string>$SERVER_PY</string>
    <string>--backend</string>
    <string>$BACKEND</string>
  </array>
  <key>WorkingDirectory</key>   <string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>             <string>$path_value</string>
    <key>HOME</key>             <string>$HOME</string>
  </dict>
  <key>RunAtLoad</key>          <true/>
  <key>KeepAlive</key>          <true/>
  <key>ThrottleInterval</key>   <integer>10</integer>
  <key>ProcessType</key>        <string>Interactive</string>
  <key>StandardOutPath</key>    <string>$LOG</string>
  <key>StandardErrorPath</key>  <string>$LOG</string>
</dict>
</plist>
PLIST
  plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die "generated plist failed plutil lint"; }
  mv "$tmp" "$PLIST"
  say "· wrote $PLIST"
}

_loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# bootout/bootstrap are ASYNC — the domain takes a moment to settle. Poll so the
# caller never races (an immediate re-bootstrap after bootout otherwise fails).
_wait_unloaded() { local _; for _ in $(seq 1 20); do _loaded || return 0; sleep 0.5; done; return 1; }
_wait_loaded()   { local _; for _ in $(seq 1 20); do _loaded && return 0; sleep 0.5; done; return 1; }

_bootout() { launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true; _wait_unloaded || true; }

# Retry bootstrap a few times: right after a bootout the domain can briefly
# reject a new load. Surface the real error only if every attempt fails.
_bootstrap() {
  local _
  for _ in 1 2 3 4; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && return 0
    sleep 1
  done
  launchctl bootstrap "$DOMAIN" "$PLIST"
}

wait_health() {
  local ts url
  ts="$(tailscale_ip)"; url="http://${ts:-127.0.0.1}:$PORT/health"
  say "· waiting for health at $url …"
  for _ in $(seq 1 40); do
    curl -fsS -m 2 "$url" >/dev/null 2>&1 && { say "· healthy ✓"; return 0; }
    sleep 1
  done
  say "· not healthy yet — first model load can be slow; check: $(basename "$0") logs"
}

cmd_install() {
  ensure_venv
  stop_manual
  write_plist
  _bootout                       # idempotent re-install: clear any prior load
  _bootstrap || die "launchctl bootstrap failed"
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  wait_health
  say ""
  cmd_status
}

cmd_uninstall() {
  if _loaded; then _bootout; say "· unloaded $LABEL"; fi
  stop_manual
  [ -f "$PLIST" ] && { rm -f "$PLIST"; say "· removed $PLIST"; }
  say "· logs kept at $LOG (delete by hand if you want)"
  say "uninstalled — the ASR server will no longer start at login."
}

cmd_start() {
  [ -f "$PLIST" ] || die "not installed — run: $(basename "$0") install"
  if _loaded; then launchctl kickstart "$DOMAIN/$LABEL"; else _bootstrap || die "launchctl bootstrap failed"; fi
  _wait_loaded || true
  wait_health
}

cmd_stop() {
  _bootout
  if _loaded; then
    say "· stop: still loaded — try again, or check: $(basename "$0") status"
  else
    say "· stopped (booted out) — won't respawn until '$(basename "$0") start'."
  fi
}

cmd_restart() {
  [ -f "$PLIST" ] || die "not installed — run: $(basename "$0") install"
  if _loaded; then launchctl kickstart -k "$DOMAIN/$LABEL"; else _bootstrap || die "launchctl bootstrap failed"; fi
  _wait_loaded || true
  wait_health
}

cmd_status() {
  if _loaded; then
    say "service : LOADED ($LABEL)"
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
      | grep -E '^\s*(state|pid) =' | sed 's/^[[:space:]]*/  /' || true
  else
    say "service : not loaded"
  fi
  local ts; ts="$(tailscale_ip)"; ts="${ts:-127.0.0.1}"
  if curl -fsS -m 3 "http://$ts:$PORT/health" >/dev/null 2>&1; then
    say "health  : OK   →  http://$ts:$PORT   (ws://$ts:$PORT/stream)"
  else
    say "health  : DOWN (no response on $ts:$PORT)"
  fi
  local be=""
  [ -f "$PLIST" ] && be="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" 2>/dev/null \
    | grep -iE 'parakeet|whisper' | head -1 | tr -d ' ')"
  say "backend : ${be:-whisper}"
  say "plist   : $PLIST"
  say "logs    : $LOG"
}

cmd_logs() {
  [ -f "$LOG" ] || die "no log yet at $LOG"
  tail -n "${1:-80}" "$LOG"
  say "--- (live: tail -f \"$LOG\") ---"
}

usage() {
  cat <<USAGE
Talk to Claude — ASR server service (macOS LaunchAgent)

  $(basename "$0") install     set up auto-start at login + start now (respawns on crash)
  $(basename "$0") uninstall   stop + remove auto-start (plist removed, logs kept)
  $(basename "$0") start       load + start the service
  $(basename "$0") stop        stop the service (stays down until 'start')
  $(basename "$0") restart     restart the running service
  $(basename "$0") status      load state + health + paths
  $(basename "$0") logs [N]    last N log lines (default 80)
USAGE
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  logs)      cmd_logs "${2:-}" ;;
  *)         usage; exit 1 ;;
esac
