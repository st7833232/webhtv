#!/usr/bin/env python3
"""Decode every recorded frame of a simulator recording of the IOS-POC-25 test streams.

usage: analyze.py runs/<name>.mp4 <x>:<y>:<w>:<h> [fps]
The rectangle is the 16:9 picture inside the recording, in recording pixels. Each frame's
barcode gives its playlist frame (see gen_hls.py); the background says ad (red) or main
(blue). Prints the recording as runs of consecutive pictures, each ad exposure, and the
[adskip]/[playback] log lines on the same clock (runs/<name>.log, .start).
"""
import json, os, subprocess, sys
from datetime import datetime

video, rect = sys.argv[1], sys.argv[2]
fps = float(sys.argv[3]) if len(sys.argv) > 3 else 25.0
x, y, w, h = rect.split(":")
GW, GH = 64, 36
pts = [float(l.strip(",")) for l in subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time", "-of", "csv=p=0", video],
    capture_output=True, text=True).stdout.split() if l.strip()]
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough",
                      "-vf", f"crop={w}:{h}:{x}:{y},scale={GW}:{GH}:flags=area",
                      "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
size = GW * GH * 3
frames = []
for i in range(min(len(pts), len(raw) // size)):
    px = raw[i * size:(i + 1) * size]
    at = lambda cx, cy: px[(cy * GW + cx) * 3:(cy * GW + cx) * 3 + 3]
    r, g, b = at(32, 30)
    kind = "AD" if r > 150 and b < 90 else "MAIN" if b > 80 and r < 60 else "other"
    value, ok = 0, kind != "other"
    for k in range(12):
        cr, cg, cb = at(10 + 4 * k, 18)
        lum = (cr + cg + cb) / 3
        if lum > 170: value |= 1 << k
        elif lum > 60: ok = False
    frames.append((pts[i], kind, value if ok else None))

runs, cur = [], None
for t, k, v in frames:
    if cur and cur["kind"] == k:
        cur["end"], cur["last"] = t, v if v is not None else cur["last"]
    else:
        if cur: runs.append(cur)
        cur = {"kind": k, "start": t, "end": t, "first": v, "last": v}
    if cur["first"] is None: cur["first"] = v
if cur: runs.append(cur)

fmt = lambda v: "   ?   " if v is None else f"{v / fps:7.3f}"
# Jumps: consecutive decoded frames whose playlist time moves unlike the recording's clock.
jumps, prev = [], None
for t, k, v in frames:
    if v is None: continue
    if prev and abs((v - prev[2]) / fps - (t - prev[0])) > 0.3:
        jumps.append((prev, (t, k, v)))
    prev = (t, k, v)
print(f"{os.path.basename(video)}: {len(frames)} frames; picture runs (recording time -> playlist time):")
for i, r in enumerate(runs):
    nxt = runs[i + 1]["start"] if i + 1 < len(runs) else r["end"]
    extra = f"   shown {nxt - r['start']:6.3f}s" if r["kind"] == "AD" else ""
    print(f"  {r['kind']:5} rec {r['start']:8.3f}-{r['end']:8.3f}  playlist {fmt(r['first'])}-{fmt(r['last'])}{extra}")

print("playlist jumps (last frame before -> first frame after):")
for a, b in jumps:
    print(f"  rec {a[0]:8.3f} {a[1]:5} {fmt(a[2])} -> rec {b[0]:8.3f} {b[1]:5} {fmt(b[2])}"
          f"   playlist {(b[2] - a[2]) / fps:+8.3f}s over {b[0] - a[0]:6.3f}s")

base = os.path.splitext(video)[0]
if os.path.exists(base + ".log"):
    t0 = float(open(base + ".start").read())
    print("log (recording time):")
    for line in open(base + ".log"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        msg = e.get("eventMessage", "")
        if "[adskip]" in msg or "[playback]" in msg:
            ts = datetime.strptime(e["timestamp"][:26], "%Y-%m-%d %H:%M:%S.%f").timestamp()
            print(f"  {ts - t0:8.3f}  {msg}")
