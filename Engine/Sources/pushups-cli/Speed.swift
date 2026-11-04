import Foundation
import PushUpsEngine
import SwiftUI

// What a long set costs after Vision: counting it whole (opening a clip, changing a setting), counting it
// frame by frame (live), and drawing the panel, on a set made of a clip's poses over and over.

/// `clip`'s poses repeated until `minutes` long, each repeat a frame after the last.
func repeated(_ clip: Poses, toMinutes minutes: Double) -> Poses {
    let times = clip.frames.map(\.time)
    let gap = (times[times.count - 1] - times[0]) / Double(times.count - 1)
    let span = times[times.count - 1] - times[0] + gap
    var frames: [Pose] = []
    var offset = 0.0
    while offset < minutes * 60 {
        frames += clip.frames.map { Pose(time: $0.time - times[0] + offset, joints: $0.joints) }
        offset += span
    }
    return Poses(source: clip.source, width: clip.width, height: clip.height, frames: frames)
}

@MainActor
func printSpeed(of url: URL, minutes: Double) throws {
    let clip = try Poses(contentsOf: url)
    let long = repeated(clip, toMinutes: minutes)
    let n = long.frames.count
    let fps = Double(n - 1) / (long.frames[n - 1].time - long.frames[0].time)
    let clock = ContinuousClock()
    print("\(clip.source) over and over: \(n) frames, \(fixed(long.frames[n - 1].time / 60, 1)) min at \(fixed(fps, 1)) fps; memory \(fixed(footprintMB(), 0)) MB")

    // Counting it whole, as opening a clip or moving a slider does.
    var start = clock.now
    let whole = RepCounter(poses: long, settings: Settings())
    let seconds = (clock.now - start) / .seconds(1)
    print("  counting it whole: \(fixed(seconds * 1000, 0)) ms, \(fixed(seconds / Double(n) * 1_000_000, 1)) µs a frame; "
          + "\(whole.count) reps; memory \(fixed(footprintMB(), 0)) MB")

    // Live: each frame into a live set, with the overlay on it, as the app takes each posed frame, timed one
    // by one; the slowest in each minute.
    func live(_ frames: [Pose], label: String) -> RepCounter? {
        var set = LiveSet(settings: Settings())
        var times: [Double] = [], slowestByMinute: [Double] = []
        for pose in frames {
            let frame = LiveFrame(pose: pose, presentationTime: .zero, width: long.width, height: long.height,
                                  arrived: .now, visionSeconds: 0)
            start = clock.now
            _ = set.add(frame)
            _ = set.overlay
            let took = (clock.now - start) / .seconds(1)
            times.append(took)
            let minute = Int(pose.time / 60)
            if minute >= slowestByMinute.count { slowestByMinute.append(0) }
            slowestByMinute[minute] = max(slowestByMinute[minute], took)
        }
        let sorted = times.sorted()
        print("  \(label): median \(fixed(sorted[sorted.count / 2] * 1_000_000, 1)) µs, p99 \(fixed(sorted[Int(Double(sorted.count) * 0.99)] * 1_000_000, 1)) µs a frame; "
              + "slowest frame by minute: " + slowestByMinute.map { fixed($0 * 1000, 2) + " ms" }.joined(separator: ", "))
        return set.counter
    }
    _ = live(long.frames, label: "live, frame by frame")
    // Before the plank, the counter looks for one on every frame, and the overlay picks a side: a session
    // where the arm never straightens (rep 1's deepest frame, over and over) never finds it.
    let bottom = clip.frames[whole.reps.first?.bottomFrame ?? 0]
    let noPlank = long.frames.prefix { $0.time <= min(minutes, 5) * 60 }.map { Pose(time: $0.time, joints: bottom.joints) }
    let stuck = live(noPlank, label: "live, no plank ever found (up to 5 min)")
    print("    (plank found: \(stuck?.plank != nil ? "yes" : "no"), \(stuck?.count ?? 0) reps)")

    // The panel, drawn as the app draws it live, twice a second: the set so far, at a few lengths.
    for length in [0.5, 1, 2, 5, 10, 20] where length <= minutes + 0.01 {
        var counter = RepCounter(settings: Settings(), aspect: long.aspect)
        for pose in long.frames where pose.time <= length * 60 { counter.add(pose) }
        var renders: [Double] = []
        for _ in 0..<3 {
            let renderer = ImageRenderer(content: PanelView(counter: counter, settings: Settings(), playhead: nil)
                .frame(width: 900, height: 360))
            start = clock.now
            _ = renderer.cgImage
            renders.append((clock.now - start) / .seconds(1))
        }
        print("  the panel at \(fixed(length, 1)) min (\(counter.poses.count) frames, \(counter.count) reps): drawn in \(fixed(median(renders) * 1000, 0)) ms")
    }
    print("  memory at the end: \(fixed(footprintMB(), 0)) MB")
}
