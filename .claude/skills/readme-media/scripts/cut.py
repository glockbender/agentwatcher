#!/usr/bin/env python3
"""cut.py [--sheet] [--publish] [clip …] — cut the README clips listed in clips.txt.

A clip names a take, an in and an out point, a size and a keyframe file. Times are written against
the take's marks — `@click+0.1` is a tenth of a second after the click — so a new recording with
other pauses still cuts in the right place. Positions are stage pixels from the top left. Inside the
stage the menu bar is blurred, except the Agent Watch icon at the frames the take sampled.

  --sheet     also tile every half second of each clip into <name>-sheet.png, to check by eye
  --publish   copy the clips into docs/images, then name the clips the README and clips.txt
              disagree on, and print the size of them all
  ENCODE_ONLY=1  reuse the frames of the last run: another CRF costs seconds, not a minute
  CRF=46         quality, lower is larger; 46 kept small terminal text intact (svt-av1 4.1)
"""
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
WORK = Path.home() / "Library/Caches/agent-watch-media"
REPO = Path(subprocess.check_output(["git", "-C", SCRIPTS, "rev-parse", "--show-toplevel"], text=True).strip())
FPS = 25
# While the icon changes width the edit cannot know the exact frame; around a change only the part
# both frames share stays sharp, so a neighbour never shows.
CHANGE_SLACK = 0.4


def read_marks(take):
    head, marks, icons = {}, {}, []
    for line in (WORK / f"{take}.marks").read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "@":
            marks[parts[2]] = (float(parts[1]), [float(v) for v in parts[3:7]])
        elif parts[0] == "icon":
            icons.append((float(parts[1]), [float(v) for v in parts[2:4]]))
        else:
            head[parts[0]] = [float(v) for v in parts[1:]]
    return head, marks, icons


def at(expression, marks):
    """`@name`, `@name+1.5`, `@name-0.2`, or seconds into the take."""
    match = re.fullmatch(r"@([\w-]+)([+-][\d.]+)?", expression)
    if not match:
        return float(expression)
    if match.group(1) not in marks:
        sys.exit(f"no mark {match.group(1)!r}; the take has {', '.join(marks)}")
    return marks[match.group(1)][0] + float(match.group(2) or 0)


def sharp_spans(icons, scale, stage_x, stage_w, start, end):
    """(from, to, x0, x1) in clip seconds and stage pixels where the icon stays sharp."""
    rects = []
    for t, frame in icons:
        if len(frame) == 2:
            x0 = frame[0] * scale - stage_x
            x1 = x0 + frame[1] * scale
            # Even edges, rounded inward: a crop of a 4:2:0 picture moves an odd edge by a pixel.
            rects.append((t, (int(max(0, x0) + 1) // 2 * 2, int(min(stage_w, x1)) // 2 * 2)))
        else:
            rects.append((t, None))
    spans = []
    for i, (t, rect) in enumerate(rects):
        begin = t + CHANGE_SLACK if i else -1e9
        finish = rects[i + 1][0] - CHANGE_SLACK if i + 1 < len(rects) else 1e9
        if rect and rect[1] > rect[0]:
            spans.append((begin, finish, *rect))
        if i + 1 < len(rects) and rect and rects[i + 1][1]:
            shared = (max(rect[0], rects[i + 1][1][0]), min(rect[1], rects[i + 1][1][1]))
            if shared[1] > shared[0]:
                spans.append((finish, finish + 2 * CHANGE_SLACK, *shared))
    result = []
    for a, b, x0, x1 in spans:
        a, b = max(a - start, 0), min(b - start, end - start)
        if b > a:
            result.append((a, b, x0, x1))
    return result


def stage_filter(head, icons, start, end):
    scale = head["scale"][0]
    x, y, w, h = (round(v * scale) for v in head["stage"])
    w, h = w // 2 * 2, h // 2 * 2
    graph = f"[0:v]crop={w}:{h}:{x}:{y}"
    bar = round(head["bar"][0] * scale) - y
    if bar <= 0:
        return graph + f",fps={FPS}[o]"
    spans = sharp_spans(icons, scale, x, w, start, end)
    labels = "".join(f"[p{i}]" for i in range(len(spans)))
    # boxblur's radius may not pass half the colour plane's height, a quarter of the bar's: a menu
    # bar without a notch is 25 points, and 14 was too much for it.
    radius = min(14, bar // 4)
    graph += f",split={len(spans) + 2}[base][b]{labels};[b]crop={w}:{bar}:0:0,boxblur={radius}:3[blur];"
    graph += "[base][blur]overlay=0:0[o0]"
    for i, (a, b, x0, x1) in enumerate(spans):
        graph += f";[p{i}]crop={x1 - x0}:{bar}:{x0}:0[q{i}];"
        graph += f"[o{i}][q{i}]overlay={x0}:0:enable='between(t,{a:.3f},{b:.3f})'[o{i + 1}]"
    return graph + f";[o{len(spans)}]fps={FPS}[o]"


def run(*command, quiet=False):
    # SVT-AV1 prints its configuration on every run whatever ffmpeg's log level; show it on failure only.
    done = subprocess.run([str(c) for c in command], capture_output=quiet, text=True)
    if done.returncode:
        sys.exit(f"{command[0]} failed: {done.stderr if quiet else ''}")


def cut(name, take, start_at, end_at, width, height, keys_file, sheet):
    head, marks, icons = read_marks(take)
    start, end = at(start_at, marks), at(end_at, marks)
    frames = WORK / "frames" / name
    keys = frames / "keys.txt"
    if not os.environ.get("ENCODE_ONLY"):
        frames.mkdir(parents=True, exist_ok=True)
        for old in frames.glob("*.png"):
            old.unlink()
        lines = []
        for line in (SCRIPTS / keys_file).read_text().splitlines():
            line = line.split("#")[0].split()
            if line:
                lines.append(f"{at(line[0], marks) - start:.3f} {' '.join(line[1:])}")
        keys.write_text("\n".join(lines) + "\n")
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", f"{start:.3f}", "-to", f"{end:.3f}",
            "-i", WORK / f"{take}.mov", "-filter_complex", stage_filter(head, icons, start, end),
            "-map", "[o]", frames / "s%04d.png")
        run(SCRIPTS / "aw-media", "zoom", frames, keys, frames, width, height, FPS)
    clip = WORK / f"{name}.avif"
    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-framerate", FPS, "-i", frames / "f%04d.png",
        "-c:v", "libsvtav1", "-crf", os.environ.get("CRF", "46"), "-preset", "4", "-svtav1-params", "scm=1",
        "-pix_fmt", "yuv420p", "-f", "avif", "-y", clip, quiet=True)
    print(f"{name}: {clip.stat().st_size // 1024} KB, {end - start:.1f} s")
    if sheet:
        # Every 12th frame — about every half second — four to a row.
        rows = -(-len(list(frames.glob("f*.png"))) // 48)
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-framerate", FPS, "-i", frames / "f%04d.png",
            "-vf", f"select='not(mod(n\\,12))',scale=480:-2,tile=4x{rows}:padding=4:color=white",
            "-frames:v", "1", "-y", WORK / f"{name}-sheet.png")


def check_published(listed):
    """A clip renamed or dropped left its old file behind in docs/images, and the README's sizes
    went stale: say both rather than leave them to be noticed."""
    images = REPO / "docs/images"
    readme = set(re.findall(r"docs/images/(clip-[\w-]+)\.avif", (REPO / "README.md").read_text()))
    present = {f.stem for f in images.glob("clip-*.avif")}
    for name, what in ((present - listed, "in docs/images but not in clips.txt: git rm it"),
                       (listed - readme, "in clips.txt but not in the README"),
                       (readme - listed, "in the README but not in clips.txt")):
        for clip in sorted(name):
            print(f"{clip}: {what}")
    total = sum((images / f"{clip}.avif").stat().st_size for clip in listed & present)
    print(f"all {len(listed & present)} clips in docs/images: {total // 1024} KB")


def main():
    args = sys.argv[1:]
    sheet, publish = "--sheet" in args, "--publish" in args
    wanted = [a for a in args if not a.startswith("--")]
    clips, listed = [], set()
    for line in (SCRIPTS / "clips.txt").read_text().splitlines():
        fields = line.split("#")[0].split()
        if len(fields) == 7:
            listed.add(fields[0])
            if not wanted or fields[0] in wanted:
                clips.append(fields)

    def one(fields):
        name, take, start, end, width, height, keys = fields
        cut(name, take, start, end, int(width), int(height), keys, sheet)
        if publish:
            shutil.copy(WORK / f"{name}.avif", REPO / "docs/images" / f"{name}.avif")

    # Built once here: four clips starting together would each find the binary older than its
    # source and write it at the same time.
    run(SCRIPTS / "aw-media", "screen", quiet=True)
    # One after another, nine clips took about 16 minutes. A clip is a chain of other programs, so
    # threads are enough to run several at once.
    with ThreadPoolExecutor(max_workers=4) as pool:
        for done in [pool.submit(one, fields) for fields in clips]:
            done.result()
    if publish:
        check_published(listed)


if __name__ == "__main__":
    main()
