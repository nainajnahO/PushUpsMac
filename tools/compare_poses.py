# /// script
# requires-python = "==3.11.*"
# dependencies = ["numpy==2.4.6"]
# ///
"""Apple Vision's keypoints against ViTPose+ Large's, on the same frames of every test clip.

    uv run tools/compare_poses.py            # prints the tables (Markdown), writes the figures

Reads `golden/<clip>/poses-vision.json` and `poses-vitpose.json` (the same frames: see
`tools/vitpose_poses.py`) and ViTPose's `python-vitpose.json` for where each rep's bottom and
lockout are. ViTPose is the reference: it's the demo's model.

On the near side (the side the analysis measures), per joint:
- the distance between the two models' points, in arm lengths (ViTPose's arm, upper arm plus
  forearm, median over the clip), at the bottom and at the top (lockout) of every rep, and over
  every frame; with the vertical offset (Vision minus ViTPose, positive is Vision's point lower);
- each model's frame-to-frame jitter: the median size of the second difference of the point's
  path, in arm lengths, so steady motion counts for nothing and noise for all of it;
- the frames where either model misses the joint (no person, or the `(0, 0)` sentinel).

The worst cases, the frames with the farthest single joint, are drawn as stick figures from the
JSONs alone, both models over each other, in `docs/images/keypoints/` (SVG). The clips show a
person and stay off the repository; `pushups-cli draw <clip> <poses.json>...` draws the same frames
on the clip itself, on the Mac that has it.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
GOLDEN = REPO / "golden"
FIGURES = REPO / "docs" / "images" / "keypoints"
CLIPS = ["clean-left", "clean-right", "fast-reps", "half-reps", "hips-high", "hips-low"]
JOINTS = ["shoulder", "elbow", "wrist", "hip", "knee", "ankle"]
EDGES = [(15, 13), (13, 11), (16, 14), (14, 12), (11, 12), (5, 11), (6, 12), (5, 6), (5, 7), (7, 9),
         (6, 8), (8, 10)]
WORST = 4


def keypoints(path: Path) -> tuple[np.ndarray, dict]:
    """(frames, 17, 2) normalized keypoints of each frame's first person, NaN where missing."""
    payload = json.loads(path.read_text())
    n = payload["video"]["n_frames"]
    out = np.full((n, 17, 2), np.nan)
    seen = set()
    for person in payload["content"]["items"]:
        i = person["frame_id"]
        if i in seen:
            continue   # the athlete is the first person; both files hold one a frame here
        seen.add(i)
        xy = np.array(person["kpts_xy"], dtype=float)
        xy[(xy == 0).all(axis=1)] = np.nan
        out[i] = xy
    return out, payload["video"]


def summarize(values: list[float]) -> str:
    v = np.asarray(values)
    return f"{v.mean():.3f} / {v.max():.3f}" if len(v) else "—"


def figure(path: Path, vision: np.ndarray, vitpose: np.ndarray, joint: int, title: str, aspect: float) -> None:
    """Both stick figures on a blank frame, the worst joint ringed: Vision green, ViTPose magenta."""
    w, h = 960, round(960 / aspect)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h + 40}" width="{w}" height="{h + 40}">',
             f'<rect width="{w}" height="{h + 40}" fill="#16181d"/>',
             f'<line x1="0" y1="{h}" x2="{w}" y2="{h}" stroke="#444" stroke-width="1"/>',
             f'<text x="12" y="{h + 26}" fill="#ddd" font-family="-apple-system, Helvetica" font-size="16">{title}</text>']
    for points, color in ((vitpose, "#e879f9"), (vision, "#4ade80")):
        for a, b in EDGES:
            if np.isfinite(points[[a, b]]).all():
                (x1, y1), (x2, y2) = points[a] * (w, h), points[b] * (w, h)
                parts.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{color}" '
                             f'stroke-width="3" stroke-linecap="round"/>')
        for x, y in points[5:] * (w, h):
            if np.isfinite([x, y]).all():
                parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{color}"/>')
    x, y = vitpose[joint] * (w, h)
    parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="22" fill="none" stroke="#fbbf24" stroke-width="2"/>')
    parts.append(f'<text x="{w - 12}" y="{h + 26}" fill="#ddd" font-family="-apple-system, Helvetica" font-size="16" '
                 f'text-anchor="end"><tspan fill="#4ade80">Vision</tspan>  <tspan fill="#e879f9">ViTPose</tspan></text>')
    path.write_text("\n".join(parts + ["</svg>"]) + "\n")


def main() -> None:
    rows_at = {"bottom": {j: [] for j in JOINTS}, "top": {j: [] for j in JOINTS}, "all": {j: [] for j in JOINTS}}
    offsets = {"bottom": {j: [] for j in JOINTS}, "top": {j: [] for j in JOINTS}}
    jitter = {m: {j: [] for j in JOINTS} for m in ("vision", "vitpose")}
    clip_rows, misses, worst = [], [], []
    for clip in CLIPS:
        vision, video = keypoints(GOLDEN / clip / "poses-vision.json")
        vitpose, _ = keypoints(GOLDEN / clip / "poses-vitpose.json")
        dump = json.loads((GOLDEN / clip / "python-vitpose.json").read_text())
        side, arm, aspect = dump["side"], dump["arm"], video["width"] / video["height"]
        index = {j: 5 + 2 * k + (side == "right") for k, j in enumerate(JOINTS)}
        scale = np.array([aspect, 1.0])   # frame heights, so distances are true lengths
        a, b = vision * scale, vitpose * scale
        distance = np.linalg.norm(a - b, axis=2) / arm          # (frames, 17), arm lengths
        dy = (a[..., 1] - b[..., 1]) / arm
        bottoms = [r["frames"]["bottom"] for r in dump["reps"]]
        tops = [r["frames"]["lockout"] for r in dump["reps"]]
        clip_cells = []
        for j in JOINTS:
            i = index[j]
            rows_at["bottom"][j] += distance[bottoms, i].tolist()
            rows_at["top"][j] += distance[tops, i].tolist()
            rows_at["all"][j] += distance[np.isfinite(distance[:, i]), i].tolist()
            offsets["bottom"][j] += dy[bottoms, i].tolist()
            offsets["top"][j] += dy[tops, i].tolist()
            clip_cells.append(f"{np.nanmean(distance[:, i]):.3f}")
            for model, points in (("vision", a), ("vitpose", b)):
                second = points[2:, i] - 2 * points[1:-1, i] + points[:-2, i]
                size = np.linalg.norm(second, axis=1) / arm
                jitter[model][j] += size[np.isfinite(size)].tolist()
            f = int(np.nanargmax(distance[:, i]))
            worst.append((float(distance[f, i]), clip, f, i, j, aspect, vision[f], vitpose[f]))
        clip_rows.append(f"| {clip} | {side} | {arm:.3f} | " + " | ".join(clip_cells) + " |")
        near = [index[j] for j in JOINTS]
        misses.append(f"| {clip} | {len(vision)} | {int(np.isnan(vision[:, near, 0]).any(axis=1).sum())} | "
                      f"{int(np.isnan(vitpose[:, near, 0]).any(axis=1).sum())} |")

    print("### Distance between the models, near side, arm lengths (mean / max)\n")
    print("| Joint | At the bottom of reps | At the top (lockout) | Every frame |")
    print("|---|---|---|---|")
    for j in JOINTS:
        print(f"| {j} | {summarize(rows_at['bottom'][j])} | {summarize(rows_at['top'][j])} | {summarize(rows_at['all'][j])} |")
    n_bottom = len(rows_at["bottom"]["shoulder"])
    print(f"\n{n_bottom} rep bottoms and {n_bottom} tops (ViTPose's reps, fast-reps' lie-down included), "
          f"{len(rows_at['all']['shoulder'])} frames.\n")
    print("### Vertical offset, Vision minus ViTPose, arm lengths (mean; positive is Vision's point lower)\n")
    print("| Joint | At the bottom | At the top |")
    print("|---|---|---|")
    for j in JOINTS:
        print(f"| {j} | {np.mean(offsets['bottom'][j]):+.3f} | {np.mean(offsets['top'][j]):+.3f} |")
    print("\n### Mean distance per clip, arm lengths\n")
    print("| Clip | Side | ViTPose's arm (frame heights) | " + " | ".join(JOINTS) + " |")
    print("|---|---|---|" + "---|" * len(JOINTS))
    print("\n".join(clip_rows))
    print("\n### Jitter: median frame-to-frame second difference, arm lengths\n")
    print("| Joint | Vision | ViTPose |")
    print("|---|---|---|")
    for j in JOINTS:
        print(f"| {j} | {np.median(jitter['vision'][j]):.4f} | {np.median(jitter['vitpose'][j]):.4f} |")
    print("\n### Frames where a near-side joint is missing\n")
    print("| Clip | Frames | Vision | ViTPose |")
    print("|---|---|---|---|")
    print("\n".join(misses))

    FIGURES.mkdir(parents=True, exist_ok=True)
    print("\n### The worst cases\n")
    shown = set()
    for d, clip, f, i, j, aspect, vis, vit in sorted(worst, key=lambda w: -w[0]):
        if (clip, f) in shown or len(shown) == WORST:
            continue
        shown.add((clip, f))
        name = f"{clip}-{f}.svg"
        figure(FIGURES / name, vis, vit, i, f"{clip}, frame {f}: the {j} {d:.2f} arm lengths apart", aspect)
        print(f"- {clip}, frame {f}: the {j}, {d:.2f} arm lengths apart (`docs/images/keypoints/{name}`)")


if __name__ == "__main__":
    main()
