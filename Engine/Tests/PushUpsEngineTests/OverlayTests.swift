import CoreGraphics
import Testing
@testable import PushUpsEngine

/// The overlay draws the athlete's own keypoints, green or red as the body line reads.
@Test(arguments: clipNames)
func overlayIsTheAthlete(name: String) throws {
    let poses = try Poses(contentsOf: golden(name, "poses-vision.json"))
    let analysis = analyze(poses, settings: .app)
    let byFrame = poses.byFrame
    for frame in stride(from: 0, to: poses.video.nFrames, by: 7) {
        let overlay = try #require(analysis.overlay(atSourceFrame: frame, tolerance: 14))
        #expect(overlay.keypoints == byFrame[frame][0].keypoints.map { CGPoint(x: $0[0], y: $0[1]) })
        #expect(overlay.straight == !(abs(analysis.line[frame]) > 14))
    }
}

/// A frame without the athlete shows the last one seen within 2 frames (the hand-made figure has
/// nobody on frame 90).
@Test func overlayHoldsTheAthlete() throws {
    let poses = try Poses(contentsOf: golden("synthetic", "poses-handmade.json"))
    let analysis = analyze(poses)
    let held = try #require(analysis.overlay(atSourceFrame: 90, tolerance: 15))
    #expect(held.keypoints == analysis.overlay(atSourceFrame: 89, tolerance: 15)?.keypoints)
    #expect(held.straight)   // no body line on frame 90: drawn green, as the demo does
}

/// Playback time to frame: index / fps, clamped to the clip.
@Test func sourceFrameAtTime() throws {
    let analysis = analyze(try Poses(contentsOf: golden("clean-right", "poses-vision.json")))
    let fps = 24.0
    #expect(analysis.sourceFrame(at: 0, fps: fps) == 0)
    #expect(analysis.sourceFrame(at: 1.0, fps: fps) == 24)
    #expect(analysis.sourceFrame(at: 1.02, fps: fps) == 24)
    #expect(analysis.sourceFrame(at: 99, fps: fps) == 143)
    #expect(analysis.sourceFrame(at: -1, fps: fps) == 0)
}
