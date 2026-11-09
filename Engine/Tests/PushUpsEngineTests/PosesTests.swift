import CoreGraphics
import Foundation
import Testing
@testable import PushUpsEngine

/// The repository's root, for `clips/` and `golden/`.
let repository = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A test clip in `clips/`. The clips show a person, so they aren't in the repository: without them,
/// the tests that read them are skipped.
func testClip(_ name: String) throws -> URL {
    let url = repository.appending(components: "clips", "\(name).mov")
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        try Test.cancel("clips/\(name).mov not found: the test clips stay on the Mac they were filmed for")
    }
    return url
}

/// A file in `golden/`.
func golden(_ components: String...) -> URL {
    components.reduce(repository.appending(component: "golden")) { $0.appending(component: $1) }
}

/// The clips with Vision poses in golden/, made by `pushups-cli poses clips/<clip>.mov -o
/// golden/<clip>/poses-vision.json`, with `--trim` set to the clip's `trim_seconds` in truth.json
/// (half-reps: `--trim 8`, as the athlete stands up after 8 s). Walk-in's are the poses the app recorded live, in
/// the movie (`Poses.recorded(in:)`): the ones it counted 1 rep from.
let clipNames = ["clean-left", "clean-right", "fast-reps", "half-reps", "hips-high", "hips-low", "walk-in"]

/// Every golden poses file: a frame per frame of the clip, in the order shown. The six phone clips are 4K, with
/// the athlete on every frame and each joint inside it. Walk-in, filmed by the app's camera at 1280 × 720, starts
/// before anybody is in frame, and Vision places an arm or a leg just past the frame's edge.
@Test(arguments: clipNames)
func goldenPosesAreTimed(name: String) throws {
    let poses = try Poses(contentsOf: golden(name, "poses-vision.json"))
    #expect(zip(poses.frames, poses.frames.dropFirst()).allSatisfy { $0.time < $1.time })
    guard name != "walk-in" else {
        #expect((poses.width, poses.height) == (1280, 720))
        return
    }
    #expect((poses.width, poses.height) == (3840, 2160))
    #expect(poses.frames.allSatisfy { !$0.joints.isEmpty })
    let locations = poses.frames.flatMap(\.joints.values).map(\.location)
    #expect(locations.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
}

/// An iPhone held upright stores its frames turned a quarter from how they're shown. The stored
/// frame's top-left corner is shown top-right, and its bottom-left top-left.
@Test func jointsTurnIntoTheShownFrame() {
    let stored = CGSize(width: 1920, height: 1080)
    let upright = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    let shown = CGRect(origin: .zero, size: stored).applying(upright)
    #expect(shown.size == CGSize(width: 1080, height: 1920))
    func turned(_ point: CGPoint) -> CGPoint {
        let p = point.applying(upright)
        return CGPoint(x: (p.x - shown.minX) / shown.width, y: (p.y - shown.minY) / shown.height)
    }
    #expect(turned(CGPoint(x: 0, y: 0)) == CGPoint(x: 1, y: 0))
    #expect(turned(CGPoint(x: 0, y: 1080)) == CGPoint(x: 0, y: 0))
    #expect(turned(CGPoint(x: 1920, y: 1080)) == CGPoint(x: 0, y: 1))
}

/// A frame Vision found nobody on has no time of its own: it's timed between its neighbours, and
/// at either end by the gap next to it.
@Test func framesWithoutAnybodyAreTimedBetweenTheirNeighbours() {
    let times = evenlyTimed([nil, 0.1, 0.2, nil, nil, 0.5, 0.6, nil], fallbackGap: 1)
    let expected = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
    #expect(zip(times, expected).allSatisfy { abs($0 - $1) < 1e-12 })
    #expect(evenlyTimed([nil, nil, nil], fallbackGap: 0.5) == [0, 0.5, 1])
    #expect(evenlyTimed([nil, 2, nil], fallbackGap: 0.5) == [1.5, 2, 2.5])
}

/// Vision's `VideoProcessor` on the first second of a clip: one athlete a frame, timed by their
/// presentation times, y down (the wrists, on the floor, below the shoulders). The clip's edit list
/// starts 10 ms into its first frame, which is shown for those 10 ms, and then every 1/24 s.
@Test func visionOnAClip() async throws {
    let poses = try await Poses.detect(in: testClip("clean-right"), trim: 1)
    #expect((poses.width, poses.height) == (3840, 2160))
    let times = poses.frames.map(\.time)
    #expect(times.count == 24)
    #expect(times[0] == 0 && abs(times[1] - 0.01) < 0.001)
    #expect(zip(times.dropFirst(), times.dropFirst(2)).allSatisfy { abs($1 - $0 - 1 / 24.0) < 0.002 })
    for pose in poses.frames {
        let shoulder = try #require(pose.joints[.rightShoulder]), wrist = try #require(pose.joints[.rightWrist])
        #expect(wrist.location.y > shoulder.location.y)
    }
}
