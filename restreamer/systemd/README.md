# Linux (systemd) install

```bash
sudo cp -r <checkout> /opt/unifi-cameras-on-tizen
cd /opt/unifi-cameras-on-tizen/restreamer
cp config.example.json config.json && nano config.json     # your cameras
sudo cp systemd/camtv-*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now camtv-mosaic camtv-server camtv-watchdog
```
`camtv-watchdog` restarts the mosaic if its HLS output goes stale — `Restart=always` only
catches a process that *exits*, not ffmpeg hanging while still alive. It runs as root so it
can `systemctl restart camtv-mosaic`.
On Linux there's no Local Network Privacy, so plain services are fine (no root-daemon trick
needed — though these run system-wide anyway). For hardware encoding on a Raspberry Pi, set
`"encoder": "h264_v4l2m2m"` in config.json.

## go2rtc (resilient camera connections)
Download the Linux go2rtc binary next to `camtv.py` so a camera reboot doesn't freeze a tile:
```bash
cd /opt/unifi-cameras-on-tizen/restreamer
ARCH=$(uname -m); case $ARCH in x86_64) A=amd64;; aarch64) A=arm64;; armv7l) A=arm;; esac
curl -sL "$(curl -s https://api.github.com/repos/AlexxIT/go2rtc/releases/latest | grep -oE '"browser_download_url": *"[^"]*linux_'$A'"' | head -1 | cut -d'"' -f4)" -o go2rtc
chmod +x go2rtc
sudo systemctl restart camtv-mosaic
```
`camtv.py` auto-detects it. Without it, cameras are pulled directly (less resilient).
