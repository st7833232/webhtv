#!/usr/bin/env python3
"""IOS-POC-25 simulator measurement: synthetic HLS VODs with mid-stream ads.

Every frame carries its playlist frame number as a 12-bit barcode (row of cells in the middle:
white = 1, black = 0, bit 0 on the left); main content is blue, ads are red.
Playlist timeline (frames): main 0-750, ad 750-1000, main 1000-2500, ad 2500-2750, main 2750-3750
= at 25 fps: main 0-30 s, ad 30-40, main 40-100, ad 100-110, main 110-150.

  A  ad has its own PTS (separate encode), #EXT-X-DISCONTINUITY around ads
  B  ad has its own PTS, no discontinuity tags
  C  one continuous encode (continuous PTS), discontinuity tags
  D  continuous PTS, no discontinuity tags
  E  H-D: 24 fps, 6-decimal EXTINF (50 frames = 2.083333 s), the first ad split into two
     discontinuity blocks (3 + 2 segments), own PTS, discontinuity tags

Ads live under ad/, main under main/, so the Android detector's first stage (group by
directory) flags them regardless of the tags. Requires ffmpeg with libx264 (no drawtext).
"""
import os, subprocess, shutil, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "www", "hls")
W, H, BITS, CELL = 640, 360, 12, 40
BLUE, RED = "0x103070", "0xC00000"


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"failed: {' '.join(cmd)}\n{r.stderr[-2000:]}")


def barcode(frame_expr):
    boxes = []
    for k in range(BITS):
        x = 80 + k * CELL
        boxes.append(f"drawbox=x={x + 4}:y=160:w={CELL - 8}:h=40:c=black:t=fill")
        boxes.append(f"drawbox=x={x + 4}:y=160:w={CELL - 8}:h=40:c=white:t=fill:"
                     f"enable='eq(mod(floor(({frame_expr})/{2 ** k})\\,2)\\,1)'")
    return boxes


def encode(out_dir, prefix, frames, fps, color, frame_expr, tone, red_expr=None):
    """Encode `frames` frames into 50-frame MPEG-TS segments; returns segment names."""
    os.makedirs(out_dir, exist_ok=True)
    seconds = frames / fps
    vf = ([f"drawbox=c={RED}:t=fill:enable='{red_expr}'"] if red_expr else []) + barcode(frame_expr)
    run(["ffmpeg", "-y", "-loglevel", "error",
         "-f", "lavfi", "-i", f"color=c={color}:s={W}x{H}:r={fps}:d={seconds}",
         "-f", "lavfi", "-i", f"sine=frequency={tone}:sample_rate=48000:duration={seconds}",
         "-vf", ",".join(vf), "-c:v", "libx264", "-profile:v", "main", "-pix_fmt", "yuv420p",
         "-g", "50", "-keyint_min", "50", "-sc_threshold", "0", "-bf", "0",
         "-c:a", "aac", "-b:a", "96k", "-shortest",
         "-f", "segment", "-segment_format", "mpegts", "-segment_frames",
         ",".join(str(50 * i) for i in range(1, frames // 50)),
         os.path.join(out_dir, f"{prefix}%03d.ts")])
    names = sorted(n for n in os.listdir(out_dir) if n.startswith(prefix))
    assert len(names) == frames // 50, (out_dir, prefix, len(names))
    return names


def playlist(path, pieces, extinf, disc):
    """pieces: list of (subdir, [names]) in playback order; a new piece is a new block."""
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:3",
             "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for i, (sub, names) in enumerate(pieces):
        if disc and i:
            lines.append("#EXT-X-DISCONTINUITY")
        for n in names:
            lines += [f"#EXTINF:{extinf},", f"{sub}/{n}"]
    lines.append("#EXT-X-ENDLIST")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def own_pts(name, fps, extinf, split_first_ad, disc):
    d = os.path.join(ROOT, name)
    shutil.rmtree(d, ignore_errors=True)
    # Main: one encode of the 3250 main frames; its playlist frame skips the two ads.
    main = encode(os.path.join(d, "main"), "m", 3250, fps, BLUE,
                  "n+250*gte(n\\,750)+250*gte(n\\,2250)", 440)
    ad = os.path.join(d, "ad")
    if split_first_ad:
        first = [("ad", encode(ad, "a1a", 150, fps, RED, "n+750", 1000)),
                 ("ad", encode(ad, "a1b", 100, fps, RED, "n+900", 1000))]
    else:
        first = [("ad", encode(ad, "a1", 250, fps, RED, "n+750", 1000))]
    ad2 = encode(ad, "a2", 250, fps, RED, "n+2500", 1000)
    pieces = [("main", main[:15])] + first + [("main", main[15:45]), ("ad", ad2), ("main", main[45:])]
    playlist(os.path.join(d, "index.m3u8"), pieces, extinf, disc)


def continuous(name, disc):
    d = os.path.join(ROOT, name)
    shutil.rmtree(d, ignore_errors=True)
    names = encode(os.path.join(d, "main"), "s", 3750, 25, BLUE, "n", 440,
                   red_expr="between(n\\,750\\,999)+between(n\\,2500\\,2749)")
    os.makedirs(os.path.join(d, "ad"))
    for i in list(range(15, 20)) + list(range(50, 55)):
        os.rename(os.path.join(d, "main", names[i]), os.path.join(d, "ad", names[i]))
    pieces = [("main", names[:15]), ("ad", names[15:20]), ("main", names[20:50]),
              ("ad", names[50:55]), ("main", names[55:])]
    playlist(os.path.join(d, "index.m3u8"), pieces, "2.000000", disc)


if __name__ == "__main__":
    only = sys.argv[1:] or ["A", "B", "C", "D", "E"]
    jobs = {"A": lambda: own_pts("A", 25, "2.000000", False, True),
            "B": lambda: own_pts("B", 25, "2.000000", False, False),
            "C": lambda: continuous("C", True),
            "D": lambda: continuous("D", False),
            "E": lambda: own_pts("E", 24, "2.083333", True, True)}
    for k in only:
        jobs[k]()
        print("ok", k)
