#!/usr/bin/env python3
"""Capture a Samsung account access token for signing (headless, no GUI).

Replicates what the Tizen Certificate Manager does: runs a local listener on port 4794
and prints a login URL. You open that URL in ANY browser, log into your Samsung account,
and Samsung POSTs the token back here. Writes token.json (access_token + user_id).

Usage:
  python3 capture-token.py
  # then open the printed URL in a browser and log in
"""
import http.server, urllib.parse, json, os, re, webbrowser

PORT = 4794
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "token.json")
LOGIN = ("https://account.samsung.com/mobile/account/check.do"
         "?serviceID=v285zxnl3h&actionID=StartOAuth2&accessToken=Y"
         f"&redirect_uri=http://localhost:{PORT}/signin/callback")
captured = {}

def extract(blob):
    # Samsung nests the token as URL-encoded JSON inside a `code` field of the POST body.
    dec = urllib.parse.unquote(blob)
    tok = re.search(r'"access_token"\s*:\s*"([^"]+)"', dec)
    uid = re.search(r'"userId"\s*:\s*"([^"]+)"', dec)
    if tok and uid:
        captured.update(access_token=tok.group(1), user_id=uid.group(1))
        json.dump(captured, open(OUT, "w"))
        return True
    return False

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _done(self):
        ok = bool(captured)
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b"<h1>Token captured. You can close this tab.</h1>" if ok
                         else b"<h1>Received, but no token found.</h1>")
        if ok:
            import threading; threading.Thread(target=self.server.shutdown, daemon=True).start()
    def do_GET(self):
        extract(urllib.parse.urlparse(self.path).query); self._done()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        extract(self.rfile.read(n).decode("utf-8", "replace") if n else ""); self._done()

if __name__ == "__main__":
    print("\n1. A browser will open (or copy the URL below) and log into your Samsung account:")
    print("   " + LOGIN + "\n")
    try: webbrowser.open(LOGIN)
    except Exception: pass
    srv = http.server.HTTPServer(("127.0.0.1", PORT), H)
    print(f"2. Waiting for the login callback on http://localhost:{PORT} …")
    srv.serve_forever()
    print(f"\nDone. Wrote {OUT}: user_id={captured.get('user_id')}, token captured.")
