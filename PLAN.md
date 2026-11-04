# Plan: a native push-up counter for the Mac

## What it is

PushUpsMac counts your push-ups live, as you do the set, from an iPhone on the floor used as the Mac's camera. It
times each rep and grades it for full range of motion and a straight back, and it can also open a clip of a set to
test against or to watch back. Everything runs on the Mac: no uploads, no account.

The idea comes from the [push-ups demo](https://github.com/jeremyipark/vision-demos/tree/main/push_ups) in Jeremy
Park's vision-demos (Apache-2.0). A pose model finds the body, the shoulder's height above the wrist counts the reps,
and the hip's angle off the shoulder-to-ankle line grades the back. PushUpsMac borrows that idea, not the demo's
code. Up to Day 20 it was a step-by-step port of the demo, checked against the demo's own results. After the Day 20
test pass (#20), live counting became the product, and matching the demo stopped being a goal (#49). Your own counts
in `golden/*/truth.json` are now the only yardstick.

## Decisions that still hold

- **Pose: Apple's Vision on the Mac** (`DetectHumanBodyPoseRequest`). No model to ship or convert, no MLX, no Core ML.
- **Camera: an iPhone on the floor through Continuity Camera,** side-on at floor level, or any other camera the Mac
  sees. An iPhone app can follow after v1 on the same engine (#29).
- **UI: SpektraMac's conventions.** Stock SwiftUI, system components, Apple's look and behaviour.
- **Privacy: clips stay out of the repository** (`clips/` is ignored). `golden/` holds only what the tests need:
  Vision's keypoints for each test clip (a stick figure per frame, no image) and your own counts.
- **Repository:** public on GitHub, Apache-2.0, crediting vision-demos and Jeremy Park.

## What the port measured

Days 12–14 ran ViTPose+ Large, the demo's cloud model, locally on exactly the frames Vision saw, and compared the two.
On the near side, Vision's shoulder sits within 0.03 arm lengths of ViTPose's on average. Both models give the same
rep counts on all six test clips. Vision takes 24–34 ms a frame on an M1 Pro, against ViTPose's 188–240 ms with its
person detector. So Vision stays, and differences in the results come from the method, not the model. The same work
set the defaults for a phone on the floor: down height 0.70 arm lengths (the demo's 0.40 graded 1 of your 19 reps
right) and back tolerance 14° (#46). Since #57 the arm is measured straight, at the plank, and in those units the down
height is 0.60.

## Native first

Before writing code for something, check whether an Apple framework does it, in the SDK's `.swiftinterface` files
rather than from memory. Write your own only when none fits, and say in the PR what was checked and why it didn't fit.

| Job | Done by |
|---|---|
| The body on each frame | Vision `DetectHumanBodyPoseRequest` (its 3D pose graded worse, #56) |
| A clip's frames and their times | Vision `VideoProcessor`, timed by presentation timestamps (#55) |
| The camera | `AVCaptureSession` with Continuity Camera (Phase Live) |
| Counting reps | Our own counter, after trying Create ML Components' `HumanBodyActionCounter` (#57) |
| Playing a clip | AVKit's `AVPlayerView` |
| The overlay and the panel | SwiftUI `Canvas` and Swift Charts, in the Mac's own appearance (#58) |
| The spoken count | `AVSpeechSynthesizer` (Phase Live) |

## Architecture

```
PushUpsMac/
  PushUpsMac.xcodeproj    the app target (SwiftUI)
  App/                    SwiftUI views and the app model
  Engine/                 local Swift package "PushUpsEngine"
    Sources/PushUpsEngine/  frames, poses, the analysis, the overlay and the panel
    Sources/pushups-cli/    poses (regenerates golden/*/poses-vision.json from clips/), analyze (prints the reps)
    Tests/                  Swift Testing: the counts against your truth.json, and unit tests
  golden/<clip>/          Vision's poses and your counts (truth.json)
  clips/                  your test clips (ignored by git)
```

The pipeline: frames → Vision's pose on each → one frame at a time into the counter → reps with their times and
grades, and the series the panel draws. Live and clips go through the same counter, so a set gives the same result
live and afterwards (#57).

## Test clips

Six clips of one person in one room, filmed landscape, side-on, with the phone at floor level and the whole body in
frame: a clean set facing each way, hips sagging, hips piked, half reps, and fast reps. All six are HDR (HLG); one is
60 fps. Each has your count and per-rep notes in `golden/<clip>/truth.json`. Anything tuned on them may only fit you,
so new clips (another angle, another person) are held out of tuning.

## Phases

Done: Phases 0–4, Days 1–20 (setup, poses, the analysis, Vision against ViTPose, the app for clips), and
Fundamentals (#54–#58).

### Fundamentals (#54–#58), done
Rebuilt on what the Mac provides, before going live.
- **#54** Drop what only matches the demo, and the export (it may come back later in a native form).
- **#55** Read poses with Vision's `VideoProcessor`, timed by their timestamps; poses as a plain Swift type.
- **#56** Spike: Vision's 3D body pose for grading. A measurement, merged only if it wins. It didn't: the grades stay 2D.
- **#57** Count rep by rep, the same way live and on a clip: a counter that only knows the frames so far.
- **#58** Give the panel and overlay the Mac's own look, in light and dark.

### Live (#21–#26)
- **#21** Camera capture and picker. **#22** Live pose and overlay. **#23** Live counting and grading, through #57's
  counter. **#24** Spoken count and cues. **#25** Record a live set, to reopen as a clip.
- **#26 (you)** Live test with the iPhone on the floor; fix list.

### Release (#27–#28)
- **#27** Speed and memory: nothing slower than real time on a 4K/60 clip, live keeping up with the camera.
- **#28** README with screenshots, a user guide, v1.

### After v1
iPhone app on the same engine (#29).

## How each step is checked

- **Engine:** `swift test` in `Engine/`. The counts test holds Vision's poses and the analysis against your counts
  in `truth.json`: the number of reps and each rep's range and back. A known miss is held as a known issue, linked
  to the issue that works on it, and fails the test once it stops happening.
- **App:** it builds (`xcodebuild -project PushUpsMac.xcodeproj -scheme PushUpsMac build`); you judge the overlay,
  the panel, the live feel and the spoken count yourself.

## Session routine

1. `gh issue list --milestone <current phase>`: take the lowest open issue, and branch off `main`.
2. Do what the issue asks, then run the tests and build the app.
3. PR with measured numbers, not just pass or fail, and what's left to try on the Mac; merge; delete the branch;
   check the issue closed.
4. If a step overruns, split the rest into a new issue.
