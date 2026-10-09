#!/usr/bin/env python3
"""activity.py <take> [from] [to] — when and where the take's picture changes.

One line per 0.1 s step that differs from the step before: the take's time, the bounding box of the
change in stage pixels, and how many pixels changed (at a quarter of the size). Use it to check a
mark against the screen — a click's change should follow its mark within 0.3 s — and to find a
target the take did not mark.
"""
import subprocess
import sys
from pathlib import Path

WORK = Path.home() / "Library/Caches/agent-watch-media"
take = sys.argv[1]
start = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
end = sys.argv[3] if len(sys.argv) > 3 else None
head = {}
for line in (WORK / f"{take}.marks").read_text().splitlines():
    parts = line.split()
    if parts and parts[0] in ("stage", "scale"):
        head[parts[0]] = [float(v) for v in parts[1:]]
x, y, w, h = (round(v * head["scale"][0]) for v in head["stage"])
w, h = w // 2 * 2, h // 2 * 2
step = 4  # a quarter of the size: fast, and a one-pixel blink still shows
sw, sh = w // step, h // step
command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(start)]
if end:
    command += ["-to", end]
command += ["-i", str(WORK / f"{take}.mov"),
            "-vf", f"crop={w}:{h}:{x}:{y},fps=10,scale={sw}:{sh}:flags=area,format=gray", "-f", "rawvideo", "-"]
data = subprocess.run(command, capture_output=True, check=True).stdout
size = sw * sh
previous = None
for i in range(len(data) // size):
    frame = data[i * size:(i + 1) * size]
    if previous is not None:
        xs, ys = [], []
        for j in range(size):
            if abs(frame[j] - previous[j]) > 12:
                xs.append(j % sw)
                ys.append(j // sw)
        if xs:
            print(f"{start + i / 10:6.1f}s  x {min(xs) * step:4d}-{(max(xs) + 1) * step:4d}"
                  f"  y {min(ys) * step:4d}-{(max(ys) + 1) * step:4d}  {len(xs):5d} px")
    previous = frame
