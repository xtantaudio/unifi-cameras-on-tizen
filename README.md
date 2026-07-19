# UniFi Cameras on Tizen

A native **Samsung Smart TV (Tizen)** app that shows your **UniFi Protect** (or any RTSP)
cameras as a **live grid**, with a **D-pad → fullscreen** picker. Runs entirely on your own
network — no cloud, no subscription, and **no dependency on Home Assistant** or anything else.

- Live **N-camera grid** (2×2, 3×3, whatever you configure), one HLS stream on the TV
- **Arrow keys** move a highlight; **OK** blows a camera up to fullscreen; **Left/Right** cycle; **Back** returns to the grid
- Pick **which** cameras, **how many**, and their **order** by editing one config file
- Works with any camera that exposes **RTSP**
- **Resilient**: go2rtc auto-reconnects dropped cameras, a watchdog restarts the stream if it
  stalls, and the TV app reconnects itself — a wall display recovers without anyone touching it

```
  UniFi Protect / any RTSP camera
            │  rtsp://…
            ▼
  ┌───────────────────────────────────┐   an always-on box you own
  │  restreamer  (this repo)          │   (Windows, Mac, Linux, a Raspberry Pi…)
  │   go2rtc (auto-reconnect cameras) │
  │     → ffmpeg → mosaic + per-cam   │
  │     → HLS on http://HOST:8099     │
  └───────────────────────────────────┘
            │  HLS (http)
            ▼
     Samsung Tizen TV  ── the app (this repo)
```

## Why a restreamer? (read this first)

Most consumer TV's cannot play RTSP streams, that is why ubiquiti (unifi) sells their rediculously
overpriced HDMI tv adapter.  This eleminates the need to spend additional money for another Unifi
product.  You do NOT need to spend more money if you already have a device to run the restreamer.
Samsung consumer TVs **cannot play RTSP** — their video player (AVPlay) only speaks HLS/DASH/MP4.
And the TV has **one hardware decoder**, so it can't decode several camera streams at once. This
project solves both with a tiny **restreamer** on a machine you already leave on: `ffmpeg` pulls
your RTSP cameras, composites them into **one** HLS "mosaic" stream (so the TV decodes a single
stream but sees the whole grid), and also serves each camera on its own for the fullscreen view.

So there are **two parts**: the **restreamer** (a couple of small services) and the **TV app**.
You need both.

## Requirements

- A **Samsung Tizen TV** (2020+ / Tizen 5.5+). Tested on a 2023 CU8000.
- An **always-on host** on the same LAN to run the restreamer: **Windows, macOS, Linux, or a
  Raspberry Pi**. Needs `ffmpeg` and `python3` on PATH.
- Your cameras' **RTSP URLs**. For UniFi Protect: enable RTSP per-camera in Protect, then the URL
  is `rtsp://<NVR-IP>:7447/<alias>`.
- To build/install the app: **Tizen Studio CLI** on a Mac/Linux/Windows machine, a free **Samsung
  account**, and **Developer Mode** enabled on the TV. (One-time; see Part 3.)

---

## Part 1 — Set up the restreamer

On the always-on host:

```bash
git clone https://github.com/xtantaudio/unifi-cameras-on-tizen.git
cd unifi-cameras-on-tizen/restreamer
cp config.example.json config.json
# edit config.json: list your cameras (name + rtsp url), and the grid (cols x rows)
```

`config.json` is the **only** file you edit to choose cameras, count, and order:

```json
{
  "grid": { "cols": 2, "rows": 2 },
  "cameras": [
    { "name": "Front Door", "url": "rtsp://10.0.0.5:7447/aaaa" },
    { "name": "Backyard",   "url": "rtsp://10.0.0.5:7447/bbbb" },
    { "name": "Garage",     "url": "rtsp://10.0.0.5:7447/cccc" },
    { "name": "Driveway",   "url": "rtsp://10.0.0.5:7447/dddd" }
  ]
}
```

- **Which cameras / how many:** add or remove entries.
- **Order (grid position):** cameras fill left→right, top→bottom, so reorder the list.
- **Layout:** set `grid.cols` × `grid.rows`. Fewer cameras than cells → the extra cells are black.

Then install the services:

**macOS**
```bash
./install-macos.sh          # downloads go2rtc, starts now + at boot, auto-restarts on failure
```
This installs three services: the **mosaic** (root LaunchDaemon), the **HLS server** (user
LaunchAgent), and the **watchdog** (root LaunchDaemon — see [Staying up](#staying-up-unattended)).
The mosaic runs as a **root LaunchDaemon** — a per-user service gets blocked by macOS "Local
Network Privacy" from reaching your cameras. On first run macOS may pop a **"allow local network"**
prompt — click **Allow**.

**Windows** (run in an **elevated** PowerShell — installs Task Scheduler jobs that start at boot
and auto-restart):
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install-windows.ps1
```
Windows has no Local Network Privacy, so a normal SYSTEM task reaches your cameras fine.

**Linux / Raspberry Pi** — see [`restreamer/systemd/README.md`](restreamer/systemd/README.md).

**Hardware encoding** (optional, lightens CPU) — set `"encoder"` in `config.json`:
`h264_videotoolbox` (macOS, default), `h264_nvenc` (NVIDIA), `h264_qsv` (Intel), `h264_amf` (AMD),
`h264_v4l2m2m` (Raspberry Pi). Default `"auto"`/`libx264` (software) works everywhere.

Verify it's serving (from any machine):
```
http://<HOST-IP>:8099/mosaic/index.m3u8     ← the grid
http://<HOST-IP>:8099/config.json           ← the camera manifest the app reads
```

---

## Part 2 — Point the app at your restreamer

```bash
cd unifi-cameras-on-tizen/app
cp js/config.example.js js/config.js
# edit js/config.js — set host to your restreamer:
#   window.CAMTV = { host: "http://<HOST-IP>:8099" };
```

`config.js` is **gitignored**, so your host never ends up in the repo — same pattern as the
restreamer's `config.json`. The build refuses to run if it's missing or still says `CHANGE_ME`.

That's the **only** app edit. Camera names, count, and grid layout are fetched from the restreamer
at runtime, so after this you change cameras by editing the restreamer's `config.json` — no app
rebuild needed.

---

## Part 3 — Build, sign, and install to your TV

Samsung requires apps to be **signed with a certificate tied to your specific TV**. This repo does
that headlessly (no flaky GUI). One-time toolchain + per-TV cert.

> **Which machine to build from:** the build/sign scripts are bash (`sdb`, `expect`, `openssl`).
> Run them on **macOS or Linux** — or on Windows via **WSL** or **Git Bash**. This is a one-time
> step to get the app onto the TV; the *restreamer* can run on Windows independently. The TV app,
> once installed, doesn't care what OS built it.

1. **Install Tizen Studio CLI** (the small "web-cli" package) from
   <http://download.tizen.org/sdk/Installer/> and install the **Samsung Certificate Extension**
   (`cert-add-on`) and TV web tools. On Apple Silicon you also need Rosetta
   (`softwareupdate --install-rosetta`). Set `TIZEN_HOME` if it's not `~/tizen-studio`.

2. **Enable Developer Mode on the TV:** Apps → type `12345` → turn Developer Mode **on** → set
   **Host PC IP** to the machine you're building from → restart the TV.

3. **Get a Samsung token** (opens a browser login to your Samsung account):
   ```bash
   python3 tools/capture-token.py
   ```

4. **Generate the cert, sign, and install** (replace with your TV's IP):
   ```bash
   ./tools/sign-and-install.sh 192.168.1.42
   ```
   This reads your TV's DUID, calls Samsung's cert API, builds the signed `.wgt`, and installs +
   launches it. After the first time, re-deploy app changes with `./tools/build-install.sh <TV_IP>`.

> **Certificates expire in ~30–90 days.** The installed app keeps running, but to *re-install* after
> that, re-run `capture-token.py` + `sign-and-install.sh`.

---

## Using it

| Button | Grid | Fullscreen |
|--------|------|------------|
| Arrows | move the highlight | Left/Right = prev/next camera |
| OK     | fullscreen the highlighted camera | back to grid |
| Back   | exit the app | back to grid |

Switching streams shows a brief "Loading…" — the TV's single decoder tears down and rebuilds
between streams (≈1–2 s). Normal.

## Staying up unattended

A wall display is only useful if it survives things going wrong at 3am without someone
relaunching an app. Three mechanisms cover three different failures, and they're independent:

| Failure | What handles it |
|---|---|
| A camera reboots or drops | **go2rtc** reconnects it; ffmpeg never sees the blip |
| The restreamer process crashes | `camtv.py` exits if either child dies, so launchd/systemd restarts the whole chain |
| **ffmpeg freezes without exiting** | the **watchdog** notices and restarts it |
| The TV loses the stream | the **app** reconnects itself |

That third row is the one that's easy to miss. `KeepAlive`/`Restart=always` only fire when a
process *exits*. A hung ffmpeg is still running, so the service manager sees a healthy service
while the picture is frozen — nothing restarts, and it stays that way until a human notices.
So the watchdog ignores process state and watches the **output** instead: if no stream has
written a new HLS segment for `STALE_SECS` (default 60), it restarts the mosaic service.

The fourth row matters just as much. Restarting the stream doesn't help if the TV has already
given up on it — the old behavior was to show "Stream error" and stay dead. The app now retries
the same URL up to 10 times, 5s apart, showing "Reconnecting…" instead, which comfortably
outlasts a restart. It also runs a 15s buffering watchdog, because AVPlay's `onerror` doesn't
reliably fire on a dead stream — it often just hangs in "buffering" forever.

Tuning (environment variables on the watchdog service):

| Variable | Default | Meaning |
|---|---|---|
| `STALE_SECS` | `60` | No new segment for this long ⇒ stalled |
| `CHECK_INTERVAL` | `300` | Seconds between checks |
| `MAX_LOG_MB` | `10` | Rotate logs above this size (`0` disables) |

Watchdog activity is logged to `restreamer/logs/watchdog.log`.

## Changing cameras later

Edit `restreamer/config.json`, then restart the restreamer:
- macOS: `sudo launchctl kickstart -k system/com.unifi-cameras.mosaic`
- Linux: `sudo systemctl restart camtv-mosaic`

Relaunch the app and it picks up the new camera set automatically.

## Troubleshooting

- **App installs but the grid is black / "Stream error":** the app can't reach the restreamer.
  Check `http://<HOST>:8099/config.json` loads from another device, and that `js/config.js` host is right.
  Note the app now shows **"Reconnecting… (n/10)"** first and only falls back to "Stream error"
  after ~50s of failed attempts — so a brief message during a restreamer restart is expected, not a fault.
- **The picture froze and nothing recovered it:** check `restreamer/logs/watchdog.log`. No
  `STALE` lines means the watchdog isn't running (`launchctl list | grep unifi-cameras` /
  `systemctl status camtv-watchdog`); `ERROR: kickstart failed` means it's running but can't
  restart the mosaic — on macOS it must be installed as a **root** LaunchDaemon to act on a
  system-domain job.
- **TV rejects the install ("Invalid certificate chain"):** cert expired, or Developer Mode / Host
  PC IP not set. Re-run Part 3.
- **`sdb connect` refused though the port is open:** the TV's Developer Mode **Host PC IP** isn't set
  to your build machine.
- **Restreamer log shows "No route to host" on macOS:** the mosaic isn't running as the root
  LaunchDaemon (`install-macos.sh` sets this up), or you haven't allowed local-network access.
- **A camera plays in the grid but black in fullscreen:** it's likely H.265/HEVC and your TV's fine
  with the mosaic (re-encoded H.264) but not the copied HEVC. Transcode that camera — see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## How it works

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design, the AVPlay/HLS constraints,
and the headless Samsung-certificate flow.

## License

MIT — see [LICENSE](LICENSE).
