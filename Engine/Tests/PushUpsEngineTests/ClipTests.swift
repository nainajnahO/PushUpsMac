import CoreGraphics
import Foundation
import ImageIO
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

/// A test clip's `trim_seconds` in `golden/<clip>/truth.json`.
func trimSeconds(_ name: String) throws -> Double? {
    let data = try Data(contentsOf: repository.appending(components: "golden", name, "truth.json"))
    return try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["trim_seconds"] as? Double
}

@Test(arguments: [
    (CGAffineTransform.identity, CGImagePropertyOrientation.up),
    (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0), .right),   // an iPhone held upright
    (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080), .down),
    (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920), .left),
])
func orientation(transform: CGAffineTransform, orientation: CGImagePropertyOrientation) {
    #expect(Clip.orientation(of: transform) == orientation)
}

/// What ffprobe says of each test clip (`nb_read_frames` with `-count_frames`, `r_frame_rate`), and
/// what the demo's own conversion makes of it (`ffmpeg -vf scale=-2:'min(1080,ih)'`, with `-t` for
/// a trimmed clip): the same frame counts. Every clip is 3840 × 2160 HDR (HLG) with no rotation.
@Test(arguments: [
    ("clean-left", 184, 24.0), ("clean-right", 144, 24.0), ("fast-reps", 334, 30.0),
    ("half-reps", 480, 60000.0 / 1001), ("hips-high", 228, 24.0), ("hips-low", 157, 24.0),
])
func framesMatchFFprobe(name: String, count: Int, fps: Double) async throws {
    let clip = try await Clip(url: testClip(name))
    #expect((clip.width, clip.height, clip.rotation, clip.isHDR) == (3840, 2160, 0, true))
    let trim = try trimSeconds(name)
    let frames = try await clip.frames(height: 1080, trim: trim)
    #expect((frames.width, frames.height) == (1920, 1080))
    var last: Frame?
    while let frame = try await frames.next() { last = frame }
    #expect(frames.count == count)
    // The 60 fps clip's timestamps run at 59.98, where ffprobe reads 59.94 from the HEVC stream:
    // 0.08 % apart. The others are exact.
    #expect(abs(frames.fps - fps) / fps < 0.001, "fps \(frames.fps), ffprobe \(fps)")
    if let trim, let last {
        // Up to the trim, as ffmpeg's -t keeps frames: the last one shown before it.
        #expect(last.time < trim && last.time + 1 / frames.fps >= trim)
    }
}
