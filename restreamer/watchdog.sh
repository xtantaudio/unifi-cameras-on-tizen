#!/usr/bin/env bash
# Restart the restreamer when its HLS output goes stale.
#
# WHY THIS EXISTS (it is not redundant with KeepAlive/Restart=always):
# camtv.py exits if either child dies, so the service manager already handles a
# CRASH. What it cannot see is ffmpeg going catatonic while still running — the
# process is alive, the service looks healthy, and no new segments are written.
# From launchd/systemd's point of view nothing is wrong, so nothing restarts, and
# the TV sits on a frozen picture until someone intervenes by hand.
#
# The only reliable liveness signal is the OUTPUT, so that is what we watch: if the
# newest .ts segment for any stream is older than STALE_SECS, restart the mosaic
# service and let the service manager bring it back.
#
# Pair this with the app-side auto-recovery in app/js/main.js — this end restarts
# the stream, that end reconnects the TV to it. Either alone leaves you half-fixed:
# a restarted stream nobody reconnects to, or a TV retrying against a dead server.
#
# Install: see install-macos.sh (root LaunchDaemon) or systemd/camtv-watchdog.service.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HLS_DIR="${HLS_DIR:-$HERE/hls}"
LOG_DIR="${LOG_DIR:-$HERE/logs}"
LOG="$LOG_DIR/watchdog.log"

STALE_SECS="${STALE_SECS:-60}"        # no new segment for this long => stalled
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
MAX_LOG_MB="${MAX_LOG_MB:-10}"        # rotate logs above this (0 disables)

# Service identifiers, per platform. Override if you renamed them.
MACOS_JOB="${MACOS_JOB:-com.unifi-cameras.mosaic}"
SYSTEMD_UNIT="${SYSTEMD_UNIT:-camtv-mosaic}"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# BSD stat (macOS) and GNU stat (Linux) take different flags.
mtime_of() {
  stat -f "%m" "$1" 2>/dev/null || stat -c "%Y" "$1" 2>/dev/null
}
size_of() {
  stat -f "%z" "$1" 2>/dev/null || stat -c "%s" "$1" 2>/dev/null
}

restart_mosaic() {
  case "$(uname -s)" in
    Darwin)
      # kickstart -k targets the job precisely and lets launchd own the respawn,
      # rather than racing KeepAlive by killing a PID we found ourselves.
      if launchctl kickstart -k "system/$MACOS_JOB" 2>/dev/null; then
        log "ACTION: kickstart -k $MACOS_JOB"
      else
        log "ERROR: kickstart failed for $MACOS_JOB (is it loaded? are we root?)"
      fi
      ;;
    Linux)
      if systemctl restart "$SYSTEMD_UNIT" 2>/dev/null; then
        log "ACTION: systemctl restart $SYSTEMD_UNIT"
      else
        log "ERROR: systemctl restart failed for $SYSTEMD_UNIT (loaded? root?)"
      fi
      ;;
    *)
      log "ERROR: unsupported platform $(uname -s) — cannot restart automatically"
      ;;
  esac
}

# Truncate in place rather than rename: the service manager holds these logs open
# on stdout/stderr and never reopens them, so a renamed file would keep collecting
# writes while the "new" log stayed empty. Keeps one previous generation.
rotate_logs() {
  [ "$MAX_LOG_MB" -gt 0 ] 2>/dev/null || return 0
  local max_bytes=$(( MAX_LOG_MB * 1024 * 1024 )) f size
  for f in "$LOG_DIR"/*.log; do
    [ -f "$f" ] || continue
    size="$(size_of "$f")" || continue
    if [ "${size:-0}" -gt "$max_bytes" ]; then
      cp "$f" "$f.1" 2>/dev/null && : > "$f"
      log "ROTATE: $(basename "$f") was $(( size / 1024 / 1024 ))MB -> truncated"
    fi
  done
}

log "Watchdog started (pid $$) stale=${STALE_SECS}s interval=${CHECK_INTERVAL}s hls=$HLS_DIR"

while true; do
  now="$(date +%s)"
  stale=""

  # Enumerate whatever streams exist rather than assuming a camera count —
  # config.json decides how many there are, and it can change without touching this.
  shopt -s nullglob
  for dir in "$HLS_DIR"/mosaic "$HLS_DIR"/cam*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"

    newest=""
    for ts in "$dir"/*.ts; do
      [ -z "$newest" ] && newest="$ts" && continue
      [ "$ts" -nt "$newest" ] && newest="$ts"
    done

    if [ -z "$newest" ]; then
      stale="$stale $name(no segments)"
      continue
    fi

    age=$(( now - $(mtime_of "$newest") ))
    [ "$age" -gt "$STALE_SECS" ] && stale="$stale $name(${age}s)"
  done
  shopt -u nullglob

  if [ -n "$stale" ]; then
    log "STALE:$stale"
    restart_mosaic
  fi

  rotate_logs
  sleep "$CHECK_INTERVAL"
done
