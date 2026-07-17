#!/usr/bin/env python3
"""Dynamic RTSP->HLS restreamer for the Tizen camera grid.

Reads config.json (cameras, order, grid) and supervises two things:

  1. go2rtc  — holds the camera RTSP connections and AUTO-RECONNECTS on drops, so a camera
               reboot/blip never reaches ffmpeg (no frozen mosaic tiles). Its config is
               generated from config.json. If the go2rtc binary isn't found, we fall back to
               pulling the cameras directly (works, but a dropped camera freezes that tile
               until the service restarts).
  2. ffmpeg  — reads the (go2rtc-fronted) streams and produces:
                 hls/mosaic/index.m3u8      the composited grid (re-encoded, HW if available)
                 hls/cam0..camN/index.m3u8  each camera on its own (stream copy) for fullscreen
                 hls/config.json            camera-name + grid manifest the TV app fetches

If EITHER child exits, this supervisor exits too — so launchd/systemd/Task Scheduler restarts
the whole chain cleanly. Change cameras/count/order/layout by editing config.json and restarting.
"""
import json, os, sys, subprocess, signal, platform, shutil, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CFG  = os.path.join(HERE, "config.json")
HLS  = os.path.join(HERE, "hls")
GO2RTC_YAML = os.path.join(HERE, "go2rtc.yaml")
GO2RTC_API  = "http://127.0.0.1:1984/api/streams"
GO2RTC_RTSP = "rtsp://127.0.0.1:8554"
CANVAS_W, CANVAS_H = 1920, 1080

def load_config():
    if not os.path.exists(CFG):
        sys.exit(f"Missing {CFG}. Copy config.example.json to config.json and edit it.")
    c = json.load(open(CFG))
    cams = [cam for cam in c.get("cameras", []) if cam.get("url")]
    if not cams:
        sys.exit("config.json has no cameras with a url.")
    grid = c.get("grid", {})
    cols = int(grid.get("cols", 1)); rows = int(grid.get("rows", 1))
    if cols * rows < len(cams):
        import math
        cols = math.ceil(math.sqrt(len(cams))); rows = math.ceil(len(cams) / cols)
    return c, cams, cols, rows

def pick_encoder(cfg):
    enc = cfg.get("encoder", "auto")
    if enc != "auto":
        return enc
    return "h264_videotoolbox" if platform.system() == "Darwin" else "libx264"

def find_go2rtc(cfg):
    """explicit config path -> bundled ./go2rtc[.exe] -> PATH -> None."""
    c = cfg.get("go2rtc")
    if c and os.path.exists(c):
        return c
    local = os.path.join(HERE, "go2rtc.exe" if platform.system() == "Windows" else "go2rtc")
    if os.path.exists(local):
        return local
    return shutil.which("go2rtc")

def write_go2rtc_yaml(cams):
    lines = ['api:', '  listen: "127.0.0.1:1984"', 'rtsp:', '  listen: ":8554"', 'streams:']
    for i, c in enumerate(cams):
        # go2rtc yaml value; RTSP URLs rarely need quoting, but wrap to be safe
        lines.append(f'  cam{i}: "{c["url"]}"')
    lines += ['log:', '  level: info']
    open(GO2RTC_YAML, "w").write("\n".join(lines) + "\n")

def wait_go2rtc(timeout=20):
    for _ in range(timeout * 2):
        try:
            urllib.request.urlopen(GO2RTC_API, timeout=2); return True
        except Exception:
            time.sleep(0.5)
    return False

def build_ffmpeg(cfg, cams, cols, rows, sources):
    ffmpeg = (cfg.get("ffmpeg") or shutil.which("ffmpeg")
              or next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/bin/ffmpeg",
                                   r"C:\ffmpeg\bin\ffmpeg.exe") if os.path.exists(p)), None)
              or "ffmpeg")
    enc = pick_encoder(cfg)
    bitrate = cfg.get("mosaic_bitrate", "6M")
    cellW, cellH = CANVAS_W // cols, CANVAS_H // rows
    cells = cols * rows

    cmd = [ffmpeg, "-nostdin", "-loglevel", "warning"]
    for url in sources:
        cmd += ["-rtsp_transport", "tcp", "-i", url]

    fc, labels = [], []
    for i in range(len(cams)):
        fc.append(f"[{i}:v]scale={cellW}:{cellH},setsar=1[c{i}]"); labels.append(f"[c{i}]")
    for j in range(len(cams), cells):
        fc.append(f"color=c=black:s={cellW}x{cellH}[c{j}]"); labels.append(f"[c{j}]")
    layout = "|".join(f"{(k % cols) * cellW}_{(k // cols) * cellH}" for k in range(cells))
    fc.append(f"{''.join(labels)}xstack=inputs={cells}:layout={layout}[out]")

    hls = ["-f", "hls", "-hls_time", "2", "-hls_list_size", "6",
           "-hls_flags", "delete_segments+omit_endlist"]
    cmd += ["-filter_complex", ";".join(fc), "-map", "[out]", "-c:v", enc, "-b:v", bitrate]
    if enc == "h264_videotoolbox":
        cmd += ["-realtime", "1"]
    elif enc == "libx264":
        cmd += ["-preset", "veryfast", "-tune", "zerolatency"]
    cmd += ["-an"] + hls + [os.path.join(HLS, "mosaic", "index.m3u8")]
    for i in range(len(cams)):
        cmd += ["-map", f"{i}:v", "-c:v", "copy", "-an"] + hls + \
               [os.path.join(HLS, f"cam{i}", "index.m3u8")]
    return cmd

def write_app_manifest(cams, cols, rows):
    """The app fetches this. Intentionally omits RTSP URLs (may hold credentials)."""
    json.dump({"grid": {"cols": cols, "rows": rows},
               "cameras": [{"name": c.get("name", f"Camera {i+1}"), "stream": f"cam{i}"}
                           for i, c in enumerate(cams)]},
              open(os.path.join(HLS, "config.json"), "w"))

def main():
    cfg, cams, cols, rows = load_config()
    os.makedirs(os.path.join(HLS, "mosaic"), exist_ok=True)
    for i in range(len(cams)):
        os.makedirs(os.path.join(HLS, f"cam{i}"), exist_ok=True)
    write_app_manifest(cams, cols, rows)

    procs = []
    def shutdown(*a):
        for p in procs:
            try: p.terminate()
            except Exception: pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    g2 = find_go2rtc(cfg)
    if g2:
        write_go2rtc_yaml(cams)
        procs.append(subprocess.Popen([g2, "-config", GO2RTC_YAML]))
        if wait_go2rtc():
            sources = [f"{GO2RTC_RTSP}/cam{i}" for i in range(len(cams))]
        else:
            print("camtv: go2rtc didn't come up; falling back to direct RTSP", flush=True)
            procs.pop().terminate()
            sources = [c["url"] for c in cams]
            g2 = None
    else:
        print("camtv: go2rtc not found — pulling cameras directly (less resilient; see README).",
              flush=True)
        sources = [c["url"] for c in cams]

    procs.append(subprocess.Popen(build_ffmpeg(cfg, cams, cols, rows, sources)))
    print(f"camtv: {len(cams)} cameras, {cols}x{rows} grid, encoder={pick_encoder(cfg)}, "
          f"go2rtc={'yes' if g2 else 'no'}", flush=True)

    # If ANY child dies, tear everything down and exit so the service manager restarts us clean.
    while True:
        for p in procs:
            if p.poll() is not None:
                print(f"camtv: child exited (rc {p.returncode}); restarting chain", flush=True)
                shutdown()
        time.sleep(2)

if __name__ == "__main__":
    main()
