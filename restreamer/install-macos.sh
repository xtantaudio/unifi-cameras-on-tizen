#!/usr/bin/env bash
# Install the restreamer as macOS services that start at boot and auto-restart.
#
# The MOSAIC runs as a root LaunchDaemon on purpose: a normal (per-user) LaunchAgent gets
# blocked by macOS "Local Network Privacy" from reaching your cameras ("No route to host").
# A system daemon isn't subject to that per-user layer. The static SERVER only listens, so
# it runs as a per-user LaunchAgent.
#
# Usage:  ./install-macos.sh          (installs + starts)
#         ./install-macos.sh uninstall
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UID_ME="$(id -u)"
DAEMON=/Library/LaunchDaemons/com.unifi-cameras.mosaic.plist
AGENT="$HOME/Library/LaunchAgents/com.unifi-cameras.server.plist"
# The watchdog restarts the mosaic daemon, which lives in the system domain, so it
# has to be a root daemon too — a user agent can't kickstart a system job.
WATCHDOG=/Library/LaunchDaemons/com.unifi-cameras.watchdog.plist
PY="$(command -v python3)"
mkdir -p "$HERE/hls" "$HERE/logs" "$HOME/Library/LaunchAgents"

if [ "${1:-}" = "uninstall" ]; then
  sudo launchctl bootout system/com.unifi-cameras.watchdog 2>/dev/null || true
  sudo launchctl bootout system/com.unifi-cameras.mosaic 2>/dev/null || true
  launchctl bootout "gui/$UID_ME/com.unifi-cameras.server" 2>/dev/null || true
  sudo rm -f "$DAEMON" "$WATCHDOG"; rm -f "$AGENT"
  echo "Uninstalled."; exit 0
fi

[ -f "$HERE/config.json" ] || { echo "Create $HERE/config.json first (copy config.example.json)."; exit 1; }

# fetch go2rtc (resilient camera connections). Skip with SKIP_GO2RTC=1 to pull cameras directly.
if [ ! -x "$HERE/go2rtc" ] && [ "${SKIP_GO2RTC:-0}" != "1" ]; then
  ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && A=amd64 || A=arm64
  URL="$(curl -s https://api.github.com/repos/AlexxIT/go2rtc/releases/latest \
        | grep -oE '"browser_download_url":\s*"[^"]*mac_'"$A"'[^"]*"' | head -1 | cut -d'"' -f4)"
  echo "Downloading go2rtc ($A)…"
  curl -sL "$URL" -o /tmp/go2rtc.zip && unzip -o -j /tmp/go2rtc.zip -d "$HERE" >/dev/null 2>&1
  mv -f "$HERE"/go2rtc_mac_* "$HERE/go2rtc" 2>/dev/null || true
  chmod +x "$HERE/go2rtc" 2>/dev/null || true
fi

# --- mosaic: root LaunchDaemon ---
sudo tee "$DAEMON" >/dev/null <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.unifi-cameras.mosaic</string>
  <key>ProgramArguments</key><array>
    <string>$PY</string><string>$HERE/camtv.py</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HERE/logs/mosaic.log</string>
  <key>StandardErrorPath</key><string>$HERE/logs/mosaic.log</string>
</dict></plist>
PL
sudo chown root:wheel "$DAEMON"

# --- server: per-user LaunchAgent ---
tee "$AGENT" >/dev/null <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.unifi-cameras.server</string>
  <key>ProgramArguments</key><array>
    <string>$PY</string><string>$HERE/serve.py</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HERE/logs/server.log</string>
  <key>StandardErrorPath</key><string>$HERE/logs/server.log</string>
</dict></plist>
PL

# --- watchdog: root LaunchDaemon (restarts the mosaic when its output goes stale) ---
sudo tee "$WATCHDOG" >/dev/null <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.unifi-cameras.watchdog</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$HERE/watchdog.sh</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HERE/logs/watchdog.log</string>
  <key>StandardErrorPath</key><string>$HERE/logs/watchdog.log</string>
</dict></plist>
PL
sudo chown root:wheel "$WATCHDOG"
chmod +x "$HERE/watchdog.sh" 2>/dev/null || true

sudo launchctl bootout system/com.unifi-cameras.mosaic 2>/dev/null || true
sudo launchctl bootstrap system "$DAEMON"
launchctl bootout "gui/$UID_ME/com.unifi-cameras.server" 2>/dev/null || true
launchctl bootstrap "gui/$UID_ME" "$AGENT"
sudo launchctl bootout system/com.unifi-cameras.watchdog 2>/dev/null || true
sudo launchctl bootstrap system "$WATCHDOG"
echo "Installed. Streams at http://<this-mac-ip>:8099/  (mosaic + cam0..N + config.json)"
echo "First run: macOS may prompt to allow local-network access — click Allow."
