#!/usr/bin/env python3
"""Local CMS + HLS server (a ./delay file throttles each .ts request) for the IOS-POC-25 simulator measurement (127.0.0.1:8765).

/config.json  one type-1 site
/api          the same CMS answer for every query: one title whose episodes are streams A-E
/hls/...      files from www/hls
"""
import http.server, json, os, time

PORT = 8765
BASE = f"http://127.0.0.1:{PORT}"
WWW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "www")
EPISODES = [("A自帶PTS有DISC", "A"), ("B自帶PTS無DISC", "B"), ("C連續PTS有DISC", "C"),
            ("D連續PTS無DISC", "D"), ("E六位小數跨區塊", "E")]
VOD = {"vod_id": 1, "vod_name": "廣告測試", "type_id": 1, "vod_pic": "", "vod_remarks": "IOS-POC-25",
       "vod_play_from": "local",
       "vod_play_url": "#".join(f"{n}${BASE}/hls/{d}/index.m3u8" for n, d in EPISODES)}
CONFIG = {"sites": [{"key": "adtest", "name": "廣告測試站", "type": 1, "api": f"{BASE}/api",
                     "searchable": 1, "quickSearch": 1}]}
CMS = {"code": 1, "page": 1, "pagecount": 1, "limit": 20, "total": 1,
       "class": [{"type_id": 1, "type_name": "測試"}], "list": [VOD]}
TYPES = {".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t"}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=WWW, **k)

    def guess_type(self, path):
        return TYPES.get(os.path.splitext(path)[1], super().guess_type(path))

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/config.json", "/api"):
            body = json.dumps(CONFIG if path == "/config.json" else CMS, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.endswith(".ts"):
            # Throttle: seconds per segment request, read from ./delay (absent or empty = none).
            try:
                time.sleep(float(open(os.path.join(os.path.dirname(WWW), "delay")).read() or 0))
            except (OSError, ValueError):
                pass
        super().do_GET()


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
