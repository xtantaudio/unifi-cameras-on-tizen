# Architecture & design notes

## The two hard TV constraints

1. **Samsung consumer TVs can't play RTSP.** AVPlay (the Tizen media API) supports HLS, DASH,
   Smooth Streaming, and progressive MP4 — not RTSP. Feed it RTSP and `prepareAsync` fails with
   `InvalidAccessError`. RTSPS doesn't help. So RTSP **must** be repackaged as HLS.

2. **One hardware decoder.** You can't reliably run 4 simultaneous AVPlay instances for a live
   grid. So the grid is composited **server-side** into a single HLS stream; the TV decodes one
   stream and sees the whole grid.

## The restreamer

`camtv.py` reads `config.json` and runs **one** ffmpeg that:
- scales each camera into a grid cell and `xstack`s them into a 1920×1080 **mosaic**, re-encoded
  to H.264 (hardware: `h264_videotoolbox` on macOS, `libx264` elsewhere, `h264_v4l2m2m` on a Pi);
- emits each camera as its own HLS via **stream copy** (no transcode) for the fullscreen view;
- writes `config.json` (camera names + grid, **no RTSP URLs**) that the app fetches.

`serve.py` is a threaded static server on :8099 with correct MIME types and CORS.

### Gotchas baked into the design
- **Clean `.m3u8` URLs.** AVPlay detects HLS by extension; a query string
  (`stream.m3u8?src=x`, e.g. go2rtc's URL) breaks detection → black screen. We serve clean paths
  like `/mosaic/index.m3u8`.
- **Decoder lifecycle.** A playing stream holds the decoder; the next `open()` fails until it's
  released. The app calls `avplay.stop()+close()` on every switch and on hide/close.
- **macOS Local Network Privacy.** A per-user LaunchAgent gets "No route to host" reaching LAN
  cameras. The mosaic runs as a **root LaunchDaemon**, which isn't subject to that per-user layer.

## HEVC cameras
UniFi cameras vary: some RTSP streams are H.264, some HEVC/H.265. The mosaic re-encodes everything
to H.264 so the grid always plays. The per-camera fullscreen streams are **copied** as-is — 4K TVs
decode HEVC fine, but if a specific camera is black in fullscreen, transcode it: change its
per-camera output in `camtv.py` from `-c:v copy` to `-c:v <encoder>`.

## The headless Samsung certificate flow
The Certificate Manager GUI is often broken (especially on Apple Silicon). `tools/` reproduces it
via Samsung's cert API:
1. `capture-token.py` runs a localhost:4794 listener and a Samsung login URL; the token comes back
   as a POST whose `code` field is URL-encoded JSON containing `access_token` + `userId`.
2. `sign-and-install.sh` reads the TV **DUID** over sdb, extracts Samsung's VD CA certs from the
   Tizen SDK plugin jar, POSTs CSRs to `https://svdca.samsungqbe.com/apis/v3/{authors,distributors}`
   (`platform=VD`), builds the `.p12`s (OpenSSL 3 `-legacy`), registers a signing profile, and
   signs+installs. Certs are DUID-locked and expire in ~30–90 days.

## Resilience: go2rtc + supervisor
ffmpeg does **not** reconnect a dropped RTSP input — if a camera blips, that input hits EOF and
the mosaic tile freezes until the process restarts. To fix this, `camtv.py` runs **go2rtc** in
front: go2rtc holds each camera's RTSP connection and auto-reconnects on drops, and ffmpeg reads
`rtsp://127.0.0.1:8554/camN` from go2rtc locally — so a camera reboot never reaches ffmpeg.

`camtv.py` is a small supervisor: it generates `go2rtc.yaml` from `config.json`, starts go2rtc,
waits for it, then starts ffmpeg. **If either child exits, the supervisor exits** so the service
manager (launchd/systemd/Task Scheduler) restarts the whole chain cleanly — which also covers the
rare case of go2rtc itself restarting. If no go2rtc binary is found, it falls back to pulling the
cameras directly (works, but without the auto-reconnect resilience). The installers download the
right go2rtc binary automatically.

### The gap that supervision can't close: a hung ffmpeg

Everything above keys off a process **exiting**. `KeepAlive` / `Restart=always` fire on exit;
`camtv.py` exits so the manager can restart the chain. None of it detects ffmpeg going catatonic
while still running — no output, but the process is alive, so the service looks healthy and
nothing restarts. In practice this is the failure that actually strands a wall display: the
picture is frozen, every dashboard says the service is up, and it stays that way until a person
notices and intervenes.

Process state is therefore the wrong signal. The only trustworthy liveness indicator is whether
**bytes are still being produced**, so `watchdog.sh` watches the output: every `CHECK_INTERVAL`
it finds the newest `.ts` segment for each stream under `hls/`, and if any is older than
`STALE_SECS` it restarts the mosaic service. It enumerates whatever stream directories exist
rather than assuming a camera count, so it follows `config.json` automatically.

It restarts via the **service manager** (`launchctl kickstart -k` / `systemctl restart`) rather
than killing a PID it found itself. That targets the right process without racing `KeepAlive`
for the restart, and keeps the manager's supervision intact. On macOS the mosaic is a
system-domain daemon, so the watchdog must be a root LaunchDaemon to act on it.

### The other half: the TV has to come back too

A restarted stream is worthless if the TV has given up on it. AVPlay's default behavior on a
dead stream is to fire `onerror` once — or, frequently, to hang in "buffering" forever without
firing anything at all — and the naive handling leaves a permanent error on screen.

So `app/js/main.js` reconnects: up to 10 attempts, 5s apart, showing "Reconnecting…" rather than
an error, which comfortably outlasts a restreamer restart. A 15s buffering watchdog covers the
case where `onerror` never fires. A monotonic `playToken` invalidates callbacks from superseded
sources, which matters because the TV has one decoder — a stale retry firing against a
torn-down player is a hard failure, not a cosmetic one.

Server-side restart and client-side reconnect are both required. Either alone leaves you
half-fixed: a stream nobody reconnects to, or a TV retrying against a server that never recovers.
