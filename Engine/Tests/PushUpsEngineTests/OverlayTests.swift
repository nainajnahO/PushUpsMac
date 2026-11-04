import CoreGraphics
import Testing
@testable import PushUpsEngine

/// The overlay draws the athlete's own joints, and which way the body line is bent past the tolerance.
@Test(arguments: clipNames)
func overlayIsTheAthlete(name: String) throws {
    let poses = try Poses(contentsOf: golden(name, "poses-vision.json"))
    let analysis = RepCounter(poses: poses, settings: Settings())
    for frame in stride(from: 0, to: poses.frames.count, by: 7) {
        let overlay = try #require(analysis.overlay(atFrame: frame, tolerance: 14))
        #expect(overlay.joints == poses.frames[frame].joints.mapValues(\.location))
        let reading = analysis.line[frame]
        #expect(overlay.bend == (abs(reading) > 14 ? (reading < 0 ? .hipsLow : .hipsHigh) : nil))
    }
}

/// A frame without the athlete shows the last one seen within 2 frames, and nothing after that.
@Test func overlayHoldsTheAthlete() throws {
    // A plank on frames 0, 1 and 5; nobody on frames 2, 3 and 4.
    let plank: [JointName: Joint] = [
        .leftShoulder: (0.3, 0.4), .leftElbow: (0.3, 0.55), .leftWrist: (0.3, 0.7),
        .leftHip: (0.55, 0.45), .leftKnee: (0.7, 0.5), .leftAnkle: (0.85, 0.55),
    ].mapValues { Joint(location: CGPoint(x: $0.0, y: $0.1), confidence: 0.9) }
    let frames = (0..<6).map { Pose(time: Double($0) / 24, joints: [2, 3, 4].contains($0) ? [:] : plank) }
    let analysis = RepCounter(poses: Poses(source: "plank", width: 1920, height: 1080, frames: frames), settings: Settings())
    let held = try #require(analysis.overlay(atFrame: 3, tolerance: 15))
    #expect(held.joints == analysis.overlay(atFrame: 1, tolerance: 15)?.joints)
    #expect(held.bend == nil)   // no body line on frame 3: drawn straight
    #expect(analysis.overlay(atFrame: 4, tolerance: 15) == nil)
}

/// Playback time to frame: the last frame shown by then, by the frames' presentation times.
@Test func frameAtTime() throws {
    let analysis = RepCounter(poses: try Poses(contentsOf: golden("clean-right", "poses-vision.json")), settings: Settings())
    // Shown at 0, 0.01, then every 1/24 s: 0.0517, 0.0933, …
    #expect(analysis.frame(at: 0) == 0)
    #expect(analysis.frame(at: 0.009) == 0)
    #expect(analysis.frame(at: 0.01) == 1)
    #expect(analysis.frame(at: 0.06) == 2)
    #expect(analysis.frame(at: 99) == analysis.times.count - 1)
    #expect(analysis.frame(at: -1) == 0)
}
