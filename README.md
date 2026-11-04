# PushUpsMac

A native push-up counter for the Mac. It counts your push-ups live from an iPhone on the floor used as the Mac's
camera, times each rep, and checks it for full range of motion and a straight back. It also opens a clip of a set, to
watch it back with the count. The body pose comes from Apple's Vision framework, so everything runs on your Mac: no
uploads, no API key.

**Status:** early work in progress. See [PLAN.md](PLAN.md) for the plan and the [issues](../../issues) for the
progress.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app |
| `Engine/` | `PushUpsEngine` Swift package (video, pose, analysis, tests) and the `pushups-cli` tool |
| `golden/` | Vision's keypoints for each test clip and your own counts, for the tests (no video) |

Requires macOS 27 or newer and Xcode 27.

## Credits and licence

Inspired by the [push-ups demo](https://github.com/jeremyipark/vision-demos/tree/main/push_ups) in
[vision-demos](https://github.com/jeremyipark/vision-demos) by Jeremy Park, licensed under Apache-2.0. The method
(counting reps from the shoulder's height above the wrist, timing each rep's phases, and grading its range of motion
and body line) comes from it. PushUpsMac is licensed under Apache-2.0 as well (see [LICENSE](LICENSE)).
