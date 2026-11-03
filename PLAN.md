# Plan: native macOS port of the vision-demos push-ups demo (Swift + Vision)

## Context

The [push-ups demo](https://github.com/jeremyipark/vision-demos/tree/main/push_ups) (Python, Apache-2.0, pinned here
to vision-demos commit `d28ca19`) counts push-ups from a side-on clip, times the concentric of every rep, and grades
each rep for full range of motion and a straight back. Its pose model, ViTPose+ Large, runs in the cloud through the
VLM Run gateway: every clip is uploaded, and an API key is needed. Everything after the pose (rep signal, counting,
phase timing, grading, the overlay and panel) is NumPy, OpenCV and matplotlib on a few numbers per frame.

Goal: a native Mac app that does the same with everything on-device, and also counts live from a camera. Work
happens in ~1–2 h sessions, one subtask per session, until the port is done.

Decisions already made:
- **Pose:** Apple's Vision framework (`DetectHumanBodyPoseRequest`) in place of ViTPose. It returns the same COCO-17
  body joints (plus neck and root). Measured on an M1 Pro: about 25 ms per 1080 × 1080 frame, and on the demo's
  thumbnail its near-side shoulder, elbow, wrist, hip and ankle land within about 11 px of ViTPose's (one frame at
  the top of a rep; the bottom of a rep is untested). No MLX and no Core ML: no model to ship or convert.
- **Platform:** one Mac app. Live input comes from an iPhone on the floor used as the Mac's camera (Continuity
  Camera), or any other camera the Mac sees. An iPhone app can follow after v1 on the same engine.
- **Repo:** public GitHub, Apache-2.0 like the original, crediting vision-demos and Jeremy Park.
- **UI:** SpektraMac's skeleton: stock SwiftUI, system components, Apple conventions.
- **Privacy:** your clips never go in the repository (`clips/` is ignored). `golden/` holds what the tests need:
  keypoints (a stick figure per frame, no image), your own rep counts, and the Python results.

## Architecture

Repo `~/Developer/PushUpsMac`:

```
PushUpsMac/
  PushUpsMac.xcodeproj        app target (SwiftUI), mirrors SpektraMac's structure
  App/                        SwiftUI views + app model
  Engine/                     local Swift package "PushUpsEngine"
    Sources/PushUpsEngine/    video frames, pose, analysis, reports
    Sources/pushups-cli/      CLI: frames, poses, analyze
    Tests/                    Swift Testing parity tests against golden/
  tools/                      Python scripts, run against a pinned vision-demos checkout
    golden.py                 runs the demo's own analysis on a poses JSON and dumps every result
    vitpose_poses.py          ViTPose+ Large run locally, for the pose comparison only
  golden/<clip>/              poses (Vision, ViTPose), your counts, Python's results
  clips/                      your test clips (ignored by git)
```

- **Pipeline shape (mirrors the demo):**
  `clip → frames → poses (gateway-shaped JSON) → near-side joints → shoulder height, body line, elbow →
  smoothed height, plank level → reps and phases → grades → reports / overlay / panel`.
  Each arrow is a testable checkpoint; the engine exposes the same intermediate series as `RepAnalysis` does.
- **The poses contract:** the engine's poses are written in the gateway's JSON shape (`vid.pose.kpts`, COCO-17
  order, top-left origin with y growing down, `(0, 0)` for an unseen joint, `kpts_score`, `bbox_xywh`, `frame_id`),
  plus the clip's fps, size and frame count. The Python analysis then runs on Apple's keypoints unchanged.
- **Precision:** the analysis is a few numbers per frame; Swift `Double` throughout, matching NumPy's float64.
- **One code path for clips and live.** Live counting re-runs the same analysis on the frames so far as frames
  arrive, so a recorded set gives the same result live and afterwards (see Phase 5 for what that costs).

### Native first

| The Python demo | PushUpsMac |
|---|---|
| ViTPose+ Large via the VLM Run gateway (cloud) | Vision `DetectHumanBodyPoseRequest` (on device) |
| ffmpeg: .mov → .mp4, rotation, trim | AVFoundation `AVAssetReader`, the track's `preferredTransform` |
| libplacebo HDR tone mapping | AVFoundation and Core Image; check an iPhone HDR clip on Day 4 |
| OpenCV + Pillow drawing on frames | SwiftUI `Canvas` over the player in the app; Core Graphics into frames for export |
| OpenCV + matplotlib panel and `plots.png` | Swift Charts; `ImageRenderer` for exported frames |
| x264 encode | `AVAssetWriter` |
| `json`, `csv` | `Codable` JSON; CSV written directly (Foundation has no CSV encoder) |
| NumPy `percentile`, `nanmedian`, `gradient`, `interp` | small Swift ports: there's no built-in with NumPy's exact definitions, and parity needs them |
| (no live input) | `AVCaptureSession` with Continuity Camera; `AVSpeechSynthesizer` for the spoken count |

## Parity strategy (how every subtask is verified)

Two separate measurements, never mixed:

1. **Math parity: same keypoints in, same results out.** `tools/golden.py` runs the pinned demo's own
   `src/reps.py` and `src/form.py` (unwrap, dedupe, `analyze`, grades, exports) on a poses JSON with the demo's
   default `config.py`, and dumps every series and result. The Swift engine runs on the *same* JSON and must agree:
   per-frame series max abs difference ≤ 1e-9 (both f64; tune and record per step), identical rep count, identical
   descent / bottom / push / lockout frames, identical grades. These tests always use the demo's defaults on the
   same keypoints and are never retuned.
2. **Model difference: Apple's keypoints against ViTPose's.** The same clips run through ViTPose+ Large locally
   (`tools/vitpose_poses.py`) and through Vision; compare the keypoints, then the counts and grades each gives.
   If Phase 3 changes the app's default thresholds, that is a documented difference in `docs/porting.md`, not a
   change to the parity tests.
3. **Ground truth:** your own rep count and notes for each test clip (which reps were partial, hips low or high)
   check the results independently of either model.

Gotchas to match:
- `np.percentile` uses linear interpolation; `np.nanmedian` ignores NaN and is NaN only for an all-NaN window.
- `np.gradient`: central differences inside, one-sided at the ends.
- `np.pad(mode="edge")` for both filters; even window sizes are bumped to the next odd size.
- `np.argmax` returns the first maximum: it decides the lockout and fastest-push frames.
- `np.interp` for gap filling; all-NaN or no-NaN series are special-cased in `_fill_gaps`.
- Times are `frame index / fps`, as in the demo, not presentation timestamps. Variable frame rate clips are a
  measured difference for later.
- The `(0, 0)` "not visible" sentinel becomes NaN; x is scaled by the aspect ratio before any angle or length.
- Vision's origin is bottom-left; the gateway's (and `body_line`'s sign) assumes y grows downward.

## Daily timeline (one subtask ≈ one 1–2 h session = one GitHub issue → branch → PR)

### Phase 0 — Setup
- **Day 1** Xcode project + `PushUpsEngine` package + `pushups-cli` skeleton, mirroring SpektraMac's build
  settings (macOS 27, Swift 6.4, default MainActor isolation, approachable concurrency, hardened runtime, sandbox,
  Swift Testing).
- **Day 2 (you)** Film the test clips and count them. Every later phase waits on this. Spec: landscape, side-on,
  camera at floor level, whole body in frame, one person, under a minute each:
  1. a clean set facing right; 2. a clean set facing left; 3. some reps with the hips sagging on purpose;
  4. some reps with the hips piked high; 5. half reps mixed with full ones (short of the floor, short of lockout);
  6. a pause at the bottom on some reps, slow and fast reps mixed. Film at least one in the iPhone's default HDR and
  one at 60 fps. For each: your rep count and, per rep, anything off. Clips go in `clips/`, your notes in
  `golden/<clip>/truth.json`.
- **Day 3** `tools/golden.py`: a pinned vision-demos checkout at `d28ca19` outside the repo; runs the demo's own
  unwrap, dedupe, `analyze` and exports on a poses JSON with the default config and dumps every series, rep and
  grade. Only NumPy needed. Record the commit and NumPy version in each dump.

### Phase 1 — Poses
- **Day 4** Clip frames with AVFoundation: decode in display orientation, nominal fps, frame count, size; trim.
  Check an iPhone HDR clip decodes with sensible brightness for Vision. `pushups-cli frames` prints what it read.
- **Day 5** Body pose per frame with `DetectHumanBodyPoseRequest`; one athlete per frame (keep the person who best
  matches the previous frame, else the largest); write the gateway-shaped poses JSON (see the contract above).
  `pushups-cli poses clip.mov -o poses.json`. Record ms per frame.

### Phase 2 — Analysis parity (same keypoints in, same results out)
- **Day 6** Near-side geometry: side pick by summed scores, side joints with aspect scaling and the `(0, 0)`
  sentinel, arm length (median), shoulder height above the wrist, body line (signed), elbow angle.
- **Day 7** Signal: gap fill, NaN-skipping median filter, centred box filter, plank level (90th percentile),
  typical depth (median of the bottoms, else the 95th percentile).
- **Day 8** Reps: hysteresis cycles, the shoulder's vertical speed, each rep's descent, bottom, push and lockout.
- **Day 9** Grades: down to the floor, back up, straight back, elbow angles reported; the tallies.
- **Day 10** Reports: the summary text, `summary.csv`, `frames.csv`, `reps.json`; `pushups-cli analyze clip.mov`
  (or a poses JSON) writes them all.
- **Day 11** Results on the test clips against your counts: Vision poses + the Swift analysis, clip by clip.
  ✅ **Milestone: a clip in, the demo's reports out, all on the Mac.**

### Phase 3 — Vision against ViTPose (can run alongside Phase 4; nothing waits on it)
- **Day 12** `tools/vitpose_poses.py`: ViTPose+ Large run locally through Hugging Face `transformers`, after a
  person detector, written in the same poses JSON. Check which ViTPose+ head is COCO before trusting the joints.
- **Day 13** Keypoint comparison: per joint, in arm lengths, at the top and at the bottom of reps, plus frame-to-frame
  jitter, on every test clip.
- **Day 14** Result comparison: counts, phase times and grades from each model's poses against your counts. Decide
  whether the app's default thresholds change, and document it in `docs/porting.md`.

### Phase 4 — App v1: clips
- **Day 15** Thin app shell from SpektraMac's skeleton: open a clip (⌘O, drag and drop), engine actor, the player,
  status bar with progress while poses run; poses cached per clip so a settings change re-analyses at once.
- **Day 16** Overlay on the playing clip: the near arm, the body line green while straight and red outside the band,
  the dashed shoulder-to-ankle reference, in sync with playback.
- **Day 17** The panel: reps, average push-up time, full-range and straight-back tallies; shoulder height over time
  with the up and floor cutoffs; body line with the band; push-up time per rep; a playhead synced to the clip.
- **Day 18** Settings: down height, up share, back tolerance, metric (moving or ascent), side; per-rep list with
  each rep's grade, click to jump there.
- **Day 19** Export: the annotated video (clip with the panel under it, square by default), the CSVs, `reps.json`
  and the summary.
- **Day 20 (you)** Real-clip test pass on new clips, against your own counts and the Python results; fix list.

### Phase 5 — Live
- **Day 21** Camera: `AVCaptureSession`, a picker listing the Mac's cameras (Continuity Camera iPhone, built-in,
  external), live preview, camera permission and entitlement.
- **Day 22** Live pose: Vision on camera frames, dropping frames when behind; the overlay live; measure fps and delay.
- **Day 23** Live counting and grading: re-run the analysis on the frames so far as frames arrive. Measure, on
  recorded sets fed in as live: (a) how long after coming back up a rep is counted (the smoothing needs about
  4 frames after it, ~130 ms at 30 fps); (b) when grades become final: a rep's lockout window runs to the next
  rep's bottom, and the plank level, arm length and side settle over the first reps. If earlier reps' counts or
  grades change, freeze a rep once its cycle closes. The final result must equal the clip analysis of the same set.
- **Day 24** Spoken count with `AVSpeechSynthesizer`; optional cue for a partial rep or a bent back.
- **Day 25** Record a live set: save the camera video and its poses, so it opens afterwards as a clip with the full
  report and export.
- **Day 26 (you)** Live test with the iPhone on the floor; fix list.

### Phase 6 — Release
- **Day 27** Speed and memory on long and 4K/60 fps clips; `tools/port_report.py` generates `docs/porting.md`
  (every ported step with its accuracy, and the Vision-against-ViTPose numbers).
- **Day 28** README with screenshots, user guide, v1 release.

≈ 28 sessions; overruns get split into new issues, not squeezed.

### After v1 (backlog)
iPhone app on the same engine · time frames by presentation timestamps for variable frame rate clips (a measured
difference) · upstream-sync routine for new vision-demos commits.

## Daily session routine
1. `gh issue list --milestone <current phase>` → take the lowest open issue; branch off `main`.
2. Refresh golden data if the subtask needs it; implement; run the parity tests.
3. PR with measured differences in the description; merge; delete the branch; close the issue.
4. If a subtask overruns, split the remainder into a new issue for the next session.

## Verification
- Engine: `swift test` in `Engine/`: per-step parity against `tools/golden.py` dumps on the same keypoints;
  results against your counts.
- CLI: `pushups-cli analyze clip.mov -o out/` compared with `tools/golden.py` on the same poses.
- App: build and run from Xcode; you judge the overlay, panel, live feel and spoken count yourself.
