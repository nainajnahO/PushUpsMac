# /// script
# requires-python = "==3.13.*"
# dependencies = [
#     "numpy==2.5.4", "pillow==13.0.0", "scipy==1.18.1",
#     "torch==2.15.0", "torchvision==0.29.2", "transformers==5.22.1",
# ]
# ///
"""ViTPose+ Large run locally, on the same frames Vision sees, written as a poses JSON.

    pushups-cli frames clips/<clip>.mov --jpeg <folder> [--trim S]     # the frames, as Vision sees them
    uv run tools/vitpose_poses.py <folder> -o golden/<clip>/poses-vitpose.json

The demo's pose model, `usyd-community/vitpose-plus-large`, runs in the cloud behind the VLM Run
gateway; here it runs on this Mac through Hugging Face `transformers`, after the person detector its
model card pairs it with, `PekingU/rtdetr_r50vd_coco_o365`. Nothing leaves the Mac after the two
models are downloaded (about 1.9 GB, into the Hugging Face cache).

The frames are the ones `pushups-cli` reads for Vision (1080 high, HDR tone-mapped to SDR by
AVFoundation, the edit list's partial first frame left out), so the two models see the same pixels
and their difference is the models'. The demo's own default sends ViTPose ffmpeg's conversion
without tone mapping; that difference isn't measured.

ViTPose+ has six expert heads, picked by `dataset_index`. Index 0 is COCO: the transformers docs
say so, and on the test clips it's the head whose joints sit on the body in COCO-17 order and agree
best with themselves on mirrored frames (checked before trusting the joints; the other heads swap
or collapse sides, or leave the body).

Per frame: the detector's person boxes (label 0) scoring at least 0.3, the best 3, each posed by
ViTPose. Every person is written; the demo's `dedupe` (in `tools/golden.py` and the engine) keeps
the athlete, as it does with the gateway's reply. Keypoints and boxes are normalized to the frame
and rounded to 4 decimals, the gateway's `PRECISION`; scores are ViTPose's heatmap peaks (not
probabilities: they can pass 1). ViTPose returns every joint, so there's no `(0, 0)` sentinel.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoProcessor, RTDetrForObjectDetection, VitPoseForPoseEstimation

DETECTOR = "PekingU/rtdetr_r50vd_coco_o365"
POSE = "usyd-community/vitpose-plus-large"
COCO = 0            # ViTPose+'s COCO expert head
PERSON = 0          # the detector's person label
MIN_SCORE = 0.3
MAX_BOXES = 3
BATCH = 8
LABELS = ["nose", "left_eye", "right_eye", "left_ear", "right_ear", "left_shoulder", "right_shoulder",
          "left_elbow", "right_elbow", "left_wrist", "right_wrist", "left_hip", "right_hip",
          "left_knee", "right_knee", "left_ankle", "right_ankle"]


def r4(value: float) -> float:
    return round(float(value), 4)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("frames", type=Path, help="a folder from `pushups-cli frames --jpeg`")
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()

    video = json.loads((args.frames / "frames.json").read_text())
    width, height = video["width"], video["height"]
    paths = [args.frames / f"{i:05d}.jpg" for i in range(video["n_frames"])]
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    det_processor = AutoProcessor.from_pretrained(DETECTOR)
    detector = RTDetrForObjectDetection.from_pretrained(DETECTOR).to(device).eval()
    pose_processor = AutoProcessor.from_pretrained(POSE)
    pose_model = VitPoseForPoseEstimation.from_pretrained(POSE).to(device).eval()
    if pose_model.config.id2label and [pose_model.config.id2label[i] for i in range(17)][5] != "L_Shoulder":
        sys.exit(f"{POSE} doesn't return COCO-17: {pose_model.config.id2label}")

    items, start, pose_seconds = [], time.perf_counter(), 0.0
    for first in range(0, len(paths), BATCH):
        batch = paths[first:first + BATCH]
        images = [Image.open(p).convert("RGB") for p in batch]
        t0 = time.perf_counter()
        with torch.inference_mode():
            found = detector(**det_processor(images=images, return_tensors="pt").to(device))
        detections = det_processor.post_process_object_detection(
            found, threshold=MIN_SCORE, target_sizes=[(height, width)] * len(images))
        boxes = []
        for d in detections:
            person = d["labels"] == PERSON
            order = d["scores"][person].argsort(descending=True)[:MAX_BOXES]
            boxes.append([[x0, y0, x1 - x0, y1 - y0] for x0, y0, x1, y1 in d["boxes"][person][order].tolist()])
        posed = [(i, b) for i, b in enumerate(boxes) if b]
        if posed:
            inputs = pose_processor([images[i] for i, _ in posed], boxes=[b for _, b in posed],
                                    return_tensors="pt").to(device)
            n_boxes = sum(len(b) for _, b in posed)
            with torch.inference_mode():
                out = pose_model(**inputs, dataset_index=torch.full((n_boxes,), COCO, device=device))
            results = pose_processor.post_process_pose_estimation(out, boxes=[b for _, b in posed])
            for (i, frame_boxes), persons in zip(posed, results):
                for box, person in zip(frame_boxes, persons):
                    items.append({
                        "frame_id": first + i,
                        "kpts_xy": [[r4(x / width), r4(y / height)] for x, y in person["keypoints"].tolist()],
                        "kpts_score": [r4(s) for s in person["scores"].tolist()],
                        "bbox_xywh": [r4(box[0] / width), r4(box[1] / height), r4(box[2] / width), r4(box[3] / height)],
                    })
        pose_seconds += time.perf_counter() - t0

    n = video["n_frames"]
    payload = {
        "video": {**video, "model": f"{POSE} (dataset_index {COCO}) after {DETECTOR}, transformers "
                                    f"{__import__('transformers').__version__}, torch {torch.__version__} on {device}",
                  "ms_per_frame": round(1000 * pose_seconds / n, 1)},
        "content": {"object": "vid.pose.kpts", "kpts_labels": LABELS,
                    "frames": [{"frame_id": i} for i in range(n)], "items": items},
    }
    args.output.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True))
    seen = len({item["frame_id"] for item in items})
    print(f"{args.output}: {n} frames, a person on {seen}, {len(items)} persons; "
          f"{1000 * pose_seconds / n:.0f} ms per frame, {time.perf_counter() - start:.0f} s in all")
    return 0


if __name__ == "__main__":
    sys.exit(main())
