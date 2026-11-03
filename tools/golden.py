# /// script
# requires-python = "==3.11.*"
# dependencies = ["numpy==2.4.6"]
# ///
"""The Python reference: the push-ups demo's own analysis on a poses JSON, every result dumped.

    uv run tools/golden.py                      # every golden/<case>/poses-<model>.json
    uv run tools/golden.py poses.json -o out.json [--fps 30 --width 1920 --height 1080]

Runs the pinned vision-demos checkout's own code, unchanged, with its default `config.py`:
`pose.unwrap` and `pose.dedupe` on the poses, `reps.analyze`, `reps.summary_text`, the two CSVs
from `export`, and `reps.json` as `main.py` writes it. The Swift engine's parity tests run on the
same poses JSON and compare against the dump.

The checkout is vision-demos at d28ca19, outside this repository (`../vision-demos` beside it by
default; `--demo` or `VISION_DEMOS` for another place). Anything else is refused:

    git clone https://github.com/jeremyipark/vision-demos ../vision-demos
    git -C ../vision-demos checkout d28ca19

Only NumPy is needed. The demo's `src/skeleton.py` imports OpenCV at the top for its drawing
functions, and `src/form.py` imports the joint names from it, so a stand-in `cv2` module is put in
place first: nothing here draws.

The poses JSON is the gateway's reply (`content.object` "vid.pose.kpts", `kpts_labels`, `frames`,
`items` with `frame_id`, `kpts_xy` normalized with y down, `(0, 0)` for an unseen joint,
`kpts_score`, `bbox_xywh`) plus a `video` object beside `content`: `fps`, `width`, `height` and
`n_frames` of the frames the model saw, and the clip's `source` file name. `--fps`, `--width` and
`--height` stand in for a JSON without it.

The dump, `golden/<case>/python-<model>.json` beside `poses-<model>.json`, is one JSON object.
Floats are written in full (shortest round-trip), and NaN is `null`:

    made_by       script, vision_demos (commit), python and numpy versions
    input         poses file name, fps, width, height, aspect (width / height), n_frames, source
    config        every config.py value the analysis reads
    dropped       persons `dedupe` removed
    indices       the source frame of each returned frame; every series below is indexed by these
    times         indices / fps, seconds
    side          "left" or "right"
    arm           arm length, frame heights
    raw           shoulder height above the wrist, arm lengths (form.shoulder_height)
    line          body line, signed degrees (form.body_line)
    elbow         near elbow angle, degrees (form.angle)
    filled        raw with its gaps filled (reps._fill_gaps)
    median        filled through the median filter (SMOOTH_MEDIAN_FRAMES)
    height        median through the box filter (SMOOTH_MEAN_FRAMES): the smoothed height
    top           the plank level, TOP_PERCENTILE of height
    depth         top - height
    amplitude     the typical rep depth (reps._robust_depth)
    rise          np.gradient(height): the shoulder's vertical speed, arm lengths per frame
    cycles        [start, bottom] array positions of each rep (reps._cycles)
    reps          each rep: its frames and times, depth, phase seconds, and its grade with every
                  field (bottom_height, top_height, top_required, back_worst, bottom_elbow,
                  top_elbow, bottom_ok, top_ok, back_ok, complete, reason, back_label)
    tally         [full range, straight back, graded]
    reps_json     reps.json's text, as main.py writes it
    summary_txt   summary.txt's text (reps.summary_text)
    summary_csv   <clip>_summary.csv's text (export.write)
    frames_csv    <clip>_frames.csv's text (export.write)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import subprocess
import sys
import tempfile
import types
from pathlib import Path

import numpy as np

COMMIT = "d28ca19ae02d0722948e1508e0cdd03d7c5eedc2"
REPO = Path(__file__).resolve().parent.parent
GOLDEN = REPO / "golden"

# What `analyze`, `grade`, the exports and the summary read from config.py.
CONFIG_KEYS = (
    "SIDE", "MAX_PERSONS", "PERSON_IOU_THRESHOLD", "SMOOTH_MEDIAN_FRAMES", "SMOOTH_MEAN_FRAMES",
    "TOP_PERCENTILE", "REP_PEAK_FRACTION", "REP_RESET_FRACTION", "CONCENTRIC_VELOCITY_FRACTION",
    "REP_METRIC", "GRADE_ROM", "ROM_DOWN_HEIGHT", "ROM_UP_FRACTION", "ROM_SAMPLE_FRAMES",
    "BACK_TOLERANCE_DEGREES", "BACK_SAMPLE_FRAMES",
)


def load_demo(path: Path):
    """The demo's `config` and `src` modules from the pinned checkout."""
    try:
        head = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit(f"{path} is not a vision-demos git checkout (see the docstring)")
    if head != COMMIT:
        sys.exit(f"{path} is at {head[:7]}, not {COMMIT[:7]}: git -C {path} checkout {COMMIT[:7]}")
    sys.modules["cv2"] = types.ModuleType("cv2")   # see the docstring: nothing here draws
    sys.path.insert(0, str(path / "push_ups"))
    import config
    from src import export, pose, reps
    return config, pose, reps, export


def floats(values) -> list:
    return [None if not math.isfinite(v) else float(v) for v in np.asarray(values, dtype=float)]


def number(value):
    value = float(value)
    return None if not math.isfinite(value) else value


def dump(poses_path: Path, out_path: Path, demo: Path, *, fps=None, width=None, height=None) -> dict:
    cfg, pose, reps, export = load_demo(demo)
    payload = json.loads(poses_path.read_text())
    video = payload.get("video") or {}
    fps = fps or video.get("fps")
    width, height = width or video.get("width"), height or video.get("height")
    if not (fps and width and height):
        sys.exit(f"{poses_path}: no video fps, width and height; pass --fps, --width and --height")
    source = video.get("source") or poses_path.name
    frames, _ = pose.unwrap(payload)
    dropped = pose.dedupe(frames, max_persons=cfg.MAX_PERSONS, iou=cfg.PERSON_IOU_THRESHOLD)
    n_frames = video.get("n_frames") or (frames[-1]["index"] + 1 if frames else 0)
    aspect = width / height

    analysis = reps.analyze(frames, fps, cfg=cfg, aspect=aspect)
    # The intermediate steps `analyze` takes, recomputed with the demo's own functions.
    filled = reps._fill_gaps(analysis.raw)
    median = reps.form.median_filter(filled, cfg.SMOOTH_MEDIAN_FRAMES)
    depth = analysis.top - analysis.height
    rise = np.gradient(analysis.height) if len(analysis.height) > 2 else np.zeros_like(analysis.height)
    amplitude = reps._robust_depth(depth)
    cycles = reps._cycles(depth, amplitude, cfg)

    rep_dumps = []
    for r in analysis.reps:
        g = r.grade
        rep_dumps.append({
            "number": r.number,
            "frames": {"descent": r.descent_frame, "bottom": r.bottom_frame, "push": r.push_frame,
                       "lockout": r.lockout_frame},
            "times": {"descent": r.descent_time, "bottom": r.bottom_time, "push": r.push_time,
                      "lockout": r.lockout_time},
            "depth": number(r.depth),
            "eccentric_seconds": r.eccentric_seconds, "pause_seconds": r.pause_seconds,
            "concentric_seconds": r.concentric_seconds, "ascent_seconds": r.ascent_seconds,
            "grade": None if g is None else {
                "bottom_height": number(g.bottom_height), "top_height": number(g.top_height),
                "top_required": number(g.top_required), "back_worst": number(g.back_worst),
                "bottom_elbow": number(g.bottom_elbow), "top_elbow": number(g.top_elbow),
                "bottom_ok": g.bottom_ok, "top_ok": g.top_ok, "back_ok": g.back_ok,
                "complete": g.complete, "reason": g.reason, "back_label": g.back_label,
            },
        })

    # reps.json as main.py writes it (main.py itself imports the renderer, so it isn't run).
    reps_json = json.dumps({
        "fps": fps,
        "signal": reps.signal_config(cfg),
        **analysis.summary(cfg.REP_METRIC),
        "series": analysis.series(),
    }, indent=2)
    summary_txt = reps.summary_text(analysis, video_seconds=n_frames / fps, source=source,
                                    metric=cfg.REP_METRIC, cfg=cfg)
    with tempfile.TemporaryDirectory() as tmp:
        stem = Path(source).stem
        summary_csv, frames_csv = export.write(analysis, Path(tmp), stem)
        summary_csv = summary_csv.read_text() if summary_csv else ""
        frames_csv = frames_csv.read_text() if frames_csv else ""

    result = {
        "made_by": {"script": "tools/golden.py", "vision_demos": COMMIT,
                    "python": platform.python_version(), "numpy": np.__version__},
        "input": {"poses": poses_path.name, "fps": fps, "width": width, "height": height,
                  "aspect": aspect, "n_frames": n_frames, "source": source},
        "config": {key: getattr(cfg, key) for key in CONFIG_KEYS},
        "dropped": dropped,
        "indices": [int(i) for i in analysis.indices],
        "times": floats(analysis.times),
        "side": analysis.side,
        "arm": number(analysis.arm),
        "raw": floats(analysis.raw),
        "line": floats(analysis.line),
        "elbow": floats(analysis.elbow),
        "filled": floats(filled),
        "median": floats(median),
        "height": floats(analysis.height),
        "top": number(analysis.top),
        "depth": floats(depth),
        "amplitude": number(amplitude),
        "rise": floats(rise),
        "cycles": [[int(a), int(b)] for a, b in cycles],
        "reps": rep_dumps,
        "tally": list(analysis.tally),
        "reps_json": reps_json,
        "summary_txt": summary_txt,
        "summary_csv": summary_csv,
        "frames_csv": frames_csv,
    }
    out_path.write_text(json.dumps(result, indent=1, allow_nan=False) + "\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("poses", nargs="?", type=Path,
                        help="a poses JSON; without one, every golden/<case>/poses-<model>.json")
    parser.add_argument("-o", "--output", type=Path, help="the dump (default: python-<model>.json beside it)")
    parser.add_argument("--demo", type=Path,
                        default=Path(os.environ.get("VISION_DEMOS", REPO.parent / "vision-demos")),
                        help="the vision-demos checkout at d28ca19 (default: ../vision-demos)")
    parser.add_argument("--fps", type=float)
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    args = parser.parse_args()

    jobs = [(args.poses, args.output)] if args.poses else [
        (p, None) for p in sorted(GOLDEN.glob("*/poses-*.json"))]
    for poses_path, out_path in jobs:
        if out_path is None:
            if not poses_path.name.startswith("poses-"):
                sys.exit(f"{poses_path}: not named poses-<model>.json, so pass -o for the dump")
            out_path = poses_path.with_name("python-" + poses_path.name.removeprefix("poses-"))
        result = dump(poses_path, out_path, args.demo.expanduser().resolve(),
                      fps=args.fps, width=args.width, height=args.height)
        full, straight, graded = result["tally"]
        print(f"{out_path.relative_to(REPO) if out_path.is_relative_to(REPO) else out_path}: "
              f"{len(result['reps'])} reps, {full}/{graded} full range, {straight}/{graded} "
              f"straight back, the {result['side']} side")
    return 0


if __name__ == "__main__":
    sys.exit(main())
