# How PushUpsMac ports the push-ups demo

PushUpsMac follows the [push-ups demo](https://github.com/jeremyipark/vision-demos/tree/main/push_ups)'s method, not its
code: each step computes what the demo's does, and Apple's frameworks do the work wherever one can. The demo is pinned
at vision-demos commit [`d28ca19`](https://github.com/jeremyipark/vision-demos/commit/d28ca19ae02d0722948e1508e0cdd03d7c5eedc2).

Two things are measured, and never mixed (see [PLAN.md](../PLAN.md#parity-strategy-how-every-subtask-is-verified)):

1. **The analysis**, on the same keypoints: [`tools/golden.py`](../tools/golden.py) runs the demo's own Python on a
   poses JSON, and the engine's parity tests (`swift test` in `Engine/`) run the Swift port on the same JSON, with the
   demo's default settings.
2. **The pose model**: Apple's Vision in place of the demo's ViTPose+ Large, both run on the same frames, against
   each other and against your own counts in `golden/<clip>/truth.json`.

## Every ported step

| The demo | PushUpsMac | Method | Measured difference |
|---|---|---|---|
| ffmpeg converts the clip to 1080 high (`scale=-2:'min(1080,ih)'`), applying the rotation | `Clip`, `Frames`: `AVAssetReader` decodes at 1080 high; the track's `preferredTransform` turns the frame | Apple's | Same frame counts as ffmpeg on every test clip (Day 4) |
| libplacebo tone-maps HDR (export only; the model sees the untone-mapped conversion) | AVFoundation converts HLG or PQ to Rec. 709 as it decodes; Vision sees tone-mapped frames | Apple's, different | The model's input differs from the demo's default for HDR clips; not measured on ViTPose |
| ffmpeg leaves out a frame the edit list cuts into | AVFoundation shows it for a few milliseconds; `Frames` leaves out a first frame shown under 0.9 of a frame | Same | 0 frames apart on every clip |
| Times: frame index / fps, fps from the conversion (`r_frame_rate`) | Frame index / fps, fps the mean gap between frames the camera didn't drop | Same, nearly | 24 and 30 fps clips exact; the 60 fps clip reads 59.98 where ffprobe says 59.94: every time 0.08 % apart. Variable frame rate is #30 |
| ViTPose+ Large through the VLM Run gateway (cloud) | Vision's `DetectHumanBodyPoseRequest` (on the Mac) | Different | See [Vision against ViTPose](#vision-against-vitpose) |
| `pose.unwrap`, `pose.dedupe` | `Poses.unwrapped()`, `dedupe` | Same | Identical persons kept |
| `form.py`: side, joints, arm length, shoulder height, body line, elbow | `Geometry.swift` | Same | 0 (bit-identical) on 13 cases |
| `_fill_gaps`, `median_filter`, `_box_filter`, `np.percentile`, `_robust_depth` | `Signal.swift` | Same | 0 on 13 cases; the box filter sums each window as a fused multiply-add in order, as NumPy's BLAS `ddot` does |
| `_cycles`, `np.gradient`, `_walk`, the phases | `Reps.swift` | Same | Identical cycles, rep counts and frames; times 0 |
| `form.grade`, the tallies, the summary numbers | `Grade.swift` | Same | Readings 0, verdicts and labels identical |
| `summary_text`, the two CSVs, `reps.json` | `Reports.swift` | Same | summary.txt and both CSVs byte-identical, reps.json equal value for value |

The 13 cases are a hand-made stick figure ([`golden/synthetic`](../golden/synthetic)), and Vision's and ViTPose's poses
of each of the six test clips.

## Vision against ViTPose

ViTPose+ Large runs on the Mac through [`tools/vitpose_poses.py`](../tools/vitpose_poses.py) on exactly the frames
Vision sees; [`tools/compare_poses.py`](../tools/compare_poses.py) compares the keypoints. On the near side, in arm
lengths, over 1,527 frames:

- **The shoulder agrees best:** 0.03 apart on average, 0.04 at the bottom of reps. At the bottom, Vision's shoulder sits
  0.02 higher and its wrist 0.02 lower, so Vision reads the shoulder about 0.03 arm lengths higher above the wrist at
  the bottom of the same rep (median +0.032 over 19 reps).
- **The folded elbow at the bottom disagrees most** (up to 0.71 apart): Vision puts it back beside the torso, ViTPose
  drops it onto the hand. The elbow is reported, not graded; it only enters through the arm length, a median over the
  clip.
- **The hip and ankle** sit higher on Vision (0.04 to 0.06 at the bottom), so Vision reads a sag about 2.7° shallower
  than ViTPose does (hips-low: −19.4, −16.2, −14.9 against −22.3, −17.8, −18.6).
- **Jitter is about the same** (Vision 0.016 to 0.026, ViTPose 0.015 to 0.024), and **neither missed** a joint or the
  person on any frame.
- **Speed:** Vision 24 to 34 ms a frame, ViTPose with its person detector 188 to 240 ms (on the GPU, M1 Pro).

The worst cases, drawn from the JSONs: [fast-reps 27](images/keypoints/fast-reps-27.svg),
[clean-left 139](images/keypoints/clean-left-139.svg), [clean-left 94](images/keypoints/clean-left-94.svg),
[half-reps 49](images/keypoints/half-reps-49.svg).

**Results.** The demo's analysis with its defaults on each model's poses gives the same rep counts on every clip
(fast-reps 5 on both, where you counted 4: lying down after the set, #42). Phase frames agree within 1.3 to 2.4 frames
on average, and push-up times within 0.07 s on average (at most 0.30 s, half-reps' last, partial rep).

## The app's default thresholds

The parity tests and `pushups-cli` keep the demo's `config.py`. The app starts from `Settings.app`:

| Setting | The demo | The app | Your 19 reps right, Vision (demo → app) | ViTPose (demo → app) |
|---|---|---|---|---|
| Down: shoulder above the wrist at the bottom, arm lengths | ≤ 0.40 | **≤ 0.70** | 1 → 18 | 5 → 18 |
| Up: share of the plank at lockout | ≥ 0.90 | ≥ 0.90 | 19 → 19 | 19 → 19 |
| Back: body line within | ±15° | **±14°** | 17 → 18 | 18 → 18 |

"Your 19 reps" are the reps you counted on the six clips (fast-reps' lie-down left out), each against your note.

### Down height: 0.70

**The demo's 0.40 doesn't fit a phone on the floor, with either model.** The demo set it on its own sample clip, where
chest-down reps read 0.22 to 0.34. On your clips, the reps you call full read 0.42 to 0.75 on Vision and 0.36 to 0.71
on ViTPose; the one you stopped short ("halfway down") reads 0.85 and 0.83. Your planks read 1.05 to 1.34 arm lengths,
over the 1.0 of a vertical straight arm: the arm length is a median over the clip, and the folded, foreshortened arm at
the bottom of each rep pulls it short, which raises every reading.

So the gap between Vision and ViTPose (+0.03) is small beside the gap between your filming and the demo's. Moving the
threshold by the model gap alone (0.43, or 0.45) would still grade most of them short: at 0.45, 14 of your 18 full reps
on Vision. Right on your 19 reps, by down height:

| Down height | 0.40 | 0.45 | 0.50 | 0.55 | 0.60 | 0.70 | 0.80 | 0.85 |
|---|---|---|---|---|---|---|---|---|
| Vision | 1 | 5 | 9 | 14 | 16 | 18 | 19 | 19 |
| ViTPose | 5 | 8 | 12 | 13 | 17 | 18 | 19 | 18 |

**0.70** sits between your full reps (mostly 0.42 to 0.66) and the halfway rep (0.85), about 70 % of the way from your
plank to a full bottom. It gets 18 of 19 on both models; the miss is hips-low's rep 1 (0.75 on Vision, 0.71 on
ViTPose). 0.80 would get all 19 on Vision, but with only 0.05 to the halfway rep. These are six clips of one person in
one room, so this is a starting point, not a fit for everyone: the app's settings change it (Day 18).

### Up share: 0.90, as the demo

Every rep you counted back up reaches at least 0.97 of the plank on both models, and the one you didn't (half-reps'
lower half) reaches 0.73. Anything from 0.80 to 0.95 gets all 19.

### Back tolerance: 14°

Vision reads a sag about 2.7° shallower than ViTPose (its hip sits higher), and hips-low's rep 3 at −14.9° slips inside
15°. At 14° it's caught, and the reps you called straight stay clear (the worst of them reads 12.3° on Vision).
Right on your 19 reps, by tolerance:

| Back tolerance | 10° | 12° | 14° | 14.5° | 15° | 15.5° | 16° | 18° | 20° |
|---|---|---|---|---|---|---|---|---|---|
| Vision | 13 | 15 | 18 | 18 | 17 | 18 | 18 | 17 | 16 |
| ViTPose | 12 | 15 | 18 | 18 | 18 | 19 | 19 | 18 | 17 |

No single tolerance gets all 19 on Vision. The other miss is half-reps' rep 1, at +15.5° on both models. A tolerance
that passes it (15.5° or more) lets hips-low's rep 3 (−14.9°) through again, and a missed sag is worse than flagging a
slight pike.

### What's left

With the app's defaults, Vision's results on your clips miss three things, each held as a known issue by the engine's
counts test (`CountsTests.swift`):

- fast-reps' lie-down after the set, counted as a 5th rep (#42)
- hips-low rep 1, 0.75 at the bottom, graded "not to the floor"
- half-reps rep 1, +15.5°, graded "hips high"
