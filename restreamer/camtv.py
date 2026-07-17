#!/usr/bin/env python3
"""Dynamic RTSP->HLS restreamer for the Tizen camera grid.

Reads config.json (cameras, order, grid), then runs ONE ffmpeg that produces:
  - hls/mosaic/index.m3u8   the composited N-camera grid (re-encoded, hardware if available)
  - hls/cam0..camN/index.m3u8  each camera on its own (stream copy, cheap) for fullscreen
  - hls/config.json         a camera-name + grid manifest the TV app fetches (NO rtsp urls)

Change cameras / count / order / layout by editing config.json and restarting. The mosaic
canvas is fixed at 1920x1080; cameras fill the grid left-to-right, top-to-bottom; empty
cells are black.
"""
import json, os, sys, subprocess, signal, platform, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
CFG  = os.path.join(HERE, "config.json")
HLS  = os.path.join(HERE, "hls")
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
        # auto-grow the grid to fit all cameras
        import math
        cols = math.ceil(math.sqrt(len(cams))); rows = math.ceil(len(cams) / cols)
    return c, cams, cols, rows

def pick_encoder(cfg):
    enc = cfg.get("encoder", "auto")
    if enc != "auto":
        return enc
    if platform.system() == "Darwin":
        return "h264_videotoolbox"
    return "libx264"

def build_ffmpeg(cfg, cams, cols, rows):
    # ffmpeg: explicit config path -> PATH lookup -> common install spots -> bare name
    ffmpeg = (cfg.get("ffmpeg") or shutil.which("ffmpeg")
              or next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/bin/ffmpeg",
                                   r"C:\ffmpeg\bin\ffmpeg.exe") if os.path.exists(p)), None)
              or "ffmpeg")
    enc = pick_encoder(cfg)
    bitrate = cfg.get("mosaic_bitrate", "6M")
    cellW, cellH = CANVAS_W // cols, CANVAS_H // rows
    cells = cols * rows

    cmd = [ffmpeg, "-nostdin", "-loglevel", "warning"]
    for cam in cams:
        cmd += ["-rtsp_transport", "tcp", "-i", cam["url"]]

    # filter graph: scale each camera to a cell; pad empty cells with black; xstack tile.
    fc = []
    labels = []
    for i in range(len(cams)):
        fc.append(f"[{i}:v]scale={cellW}:{cellH},setsar=1[c{i}]")
        labels.append(f"[c{i}]")
    for j in range(len(cams), cells):
        fc.append(f"color=c=black:s={cellW}x{cellH}[c{j}]")
        labels.append(f"[c{j}]")
    layout = "|".join(f"{(k % cols) * cellW}_{(k // cols) * cellH}" for k in range(cells))
    fc.append(f"{''.join(labels)}xstack=inputs={cells}:layout={layout}[out]")
    filter_complex = ";".join(fc)

    hls = ["-f", "hls", "-hls_time", "2", "-hls_list_size", "6",
           "-hls_flags", "delete_segments+omit_endlist"]

    cmd += ["-filter_complex", filter_complex,
            "-map", "[out]", "-c:v", enc, "-b:v", bitrate]
    if enc == "h264_videotoolbox":
        cmd += ["-realtime", "1"]
    elif enc == "libx264":
        cmd += ["-preset", "veryfast", "-tune", "zerolatency"]
    cmd += ["-an"] + hls + [os.path.join(HLS, "mosaic", "index.m3u8")]

    # per-camera single streams (stream copy — no transcode)
    for i in range(len(cams)):
        cmd += ["-map", f"{i}:v", "-c:v", "copy", "-an"] + hls + \
               [os.path.join(HLS, f"cam{i}", "index.m3u8")]
    return cmd

def write_app_manifest(cfg, cams, cols, rows):
    """The app fetches this. Intentionally omits RTSP URLs (may hold credentials)."""
    manifest = {
        "grid": {"cols": cols, "rows": rows},
        "cameras": [{"name": c.get("name", f"Camera {i+1}"), "stream": f"cam{i}"}
                    for i, c in enumerate(cams)],
    }
    json.dump(manifest, open(os.path.join(HLS, "config.json"), "w"))

def main():
    cfg, cams, cols, rows = load_config()
    os.makedirs(os.path.join(HLS, "mosaic"), exist_ok=True)
    for i in range(len(cams)):
        os.makedirs(os.path.join(HLS, f"cam{i}"), exist_ok=True)
    write_app_manifest(cfg, cams, cols, rows)
    cmd = build_ffmpeg(cfg, cams, cols, rows)
    print(f"camtv: {len(cams)} cameras, {cols}x{rows} grid, encoder={pick_encoder(cfg)}", flush=True)
    proc = subprocess.Popen(cmd)
    signal.signal(signal.SIGTERM, lambda *a: (proc.terminate(), sys.exit(0)))
    proc.wait()

if __name__ == "__main__":
    main()
