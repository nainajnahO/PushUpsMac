# PushUpsMac

A native macOS port of the [push-ups demo](https://github.com/jeremyipark/vision-demos/tree/main/push_ups) from
Jeremy Park's [vision-demos](https://github.com/jeremyipark/vision-demos): it counts push-ups from a side-on clip,
times the push of every rep, and checks each one for full range of motion and a straight back. Rewritten in Swift,
with the body pose from Apple's Vision framework, so everything runs on your Mac: no uploads, no API key. It also
counts live, from an iPhone used as the Mac's camera.

**Status:** early work in progress. See [PLAN.md](PLAN.md) for the porting plan and the [issues](../../issues) for
the day-by-day progress.

## Goals

- The same reps, phase times and grades as the Python demo, verified step by step on the same keypoints.
- Everything on-device: Apple's body pose in place of the cloud ViTPose model, with the difference measured.
- Live counting and grading from a camera, as well as from a recorded clip.
- A plain, Apple-conventional SwiftUI app: open a clip or start the camera, see the overlay and the panel, export.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app |
| `Engine/` | `PushUpsEngine` Swift package (video, pose, analysis, tests) and the `pushups-cli` tool |
| `tools/` | Python scripts that make reference data from the original demo |
| `golden/` | Reference keypoints and results for the parity tests (no video) |

Requires macOS 27 or newer and Xcode 27.

## Credits and licence

The method (the rep signal, counting, phase timing and form grades) comes from the push-ups demo in
[vision-demos](https://github.com/jeremyipark/vision-demos) by Jeremy Park, licensed under Apache-2.0. This port is
pinned to its commit
[`d28ca19`](https://github.com/jeremyipark/vision-demos/commit/d28ca19ae02d0722948e1508e0cdd03d7c5eedc2) and is
licensed under Apache-2.0 as well (see [LICENSE](LICENSE)).
