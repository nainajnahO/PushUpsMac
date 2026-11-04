import CoreImage
import Foundation
import Testing
@testable import PushUpsEngine

/// A file in `golden/`.
func golden(_ components: String...) -> URL {
    components.reduce(repository.appending(component: "golden")) { $0.appending(component: $1) }
}

/// The clips with Vision poses in golden/.
let clipNames = ["clean-left", "clean-right", "fast-reps", "half-reps", "hips-high", "hips-low"]

/// `dedupe` drops the hand-made figure's second, smaller person on frames 60 and 61.
@Test func dedupeKeepsOneAthlete() throws {
    let frames = try Poses(contentsOf: golden("synthetic", "poses-handmade.json")).byFrame
    let kept = dedupe(frames)
    #expect(kept[60] == [frames[60][0]] && kept[61] == [frames[61][0]])
    #expect(kept[90].isEmpty)
}

@Test func iouOfBoxes() {
    #expect(iou([0, 0, 1, 1], [0, 0, 1, 1]) == 1)
    #expect(iou([0, 0, 1, 1], [0.5, 0, 1, 1]) == 0.5 / 1.5)
    #expect(iou([0, 0, 1, 1], [2, 2, 1, 1]) == 0)
}

/// Every golden poses file is the gateway's shape, one athlete per frame.
@Test(arguments: clipNames)
func goldenPosesAreGatewayShaped(name: String) throws {
    let poses = try Poses(contentsOf: golden(name, "poses-vision.json"))
    #expect(poses.content.object == "vid.pose.kpts" && poses.content.kptsLabels == cocoJoints)
    #expect(poses.content.frames.map(\.frameID) == Array(0..<poses.video.nFrames))
    #expect(poses.byFrame.allSatisfy { $0.count <= 1 })
    for person in poses.content.items {
        #expect(person.keypoints.count == 17 && person.scores.count == 17)
        #expect(person.keypoints.joined().allSatisfy { (0...1).contains($0) })
    }
}

/// Vision on the first second of a clip: one person a frame, y down (the wrists, on the floor,
/// below the shoulders).
@Test func visionOnAClip() async throws {
    let clip = try await Clip(url: testClip("clean-right"))
    let poses = try await Poses.detect(in: clip, trim: 1)
    let frames = poses.byFrame
    #expect(frames.count == 24 && frames.allSatisfy { $0.count == 1 })
    for person in frames.joined() {
        let shoulder = person.keypoints[6][1], wrist = person.keypoints[10][1]   // the right side faces the camera
        #expect(wrist > shoulder)
    }
}
