# Linux (systemd) install

```bash
sudo cp -r <checkout> /opt/unifi-cameras-on-tizen
cd /opt/unifi-cameras-on-tizen/restreamer
cp config.example.json config.json && nano config.json     # your cameras
sudo cp systemd/camtv-*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now camtv-mosaic camtv-server
```
On Linux there's no Local Network Privacy, so plain services are fine (no root-daemon trick
needed — though these run system-wide anyway). For hardware encoding on a Raspberry Pi, set
`"encoder": "h264_v4l2m2m"` in config.json.
