#!/usr/bin/env python3
"""Static HTTP server for the HLS output — the TV app connects here.

Serves ~/.../restreamer/hls on port 8099: the mosaic + per-camera playlists/segments
and config.json (the app's camera manifest). Threaded, with the right MIME types and
CORS so AVPlay can pull segments freely.
"""
import http.server, socketserver, os

PORT = int(os.environ.get("CAMTV_PORT", "8099"))
HLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hls")
os.makedirs(HLS, exist_ok=True)
os.chdir(HLS)

class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()
    def guess_type(self, path):
        if path.endswith(".m3u8"): return "application/vnd.apple.mpegurl"
        if path.endswith(".ts"):   return "video/mp2t"
        if path.endswith(".json"): return "application/json"
        return super().guess_type(path)

class TS(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

if __name__ == "__main__":
    TS(("0.0.0.0", PORT), H).serve_forever()
