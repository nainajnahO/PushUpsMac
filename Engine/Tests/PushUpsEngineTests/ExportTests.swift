import AVFoundation
import Foundation
import Testing
@testable import PushUpsEngine

/// The export holds every frame of the clip, square, for as long as the clip, with the reports
/// beside it. Reads the movie back with the engine's own reader.
@MainActor
@Test func exportWritesEveryFrame() async throws {
    let clip = try await Clip(url: try testClip("hips-low"))
    let (poses, _) = try loadCase("hips-low", "vision")
    let folder = URL.temporaryDirectory.appending(component: "export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let analysis = analyze(poses, settings: .app)
    let video = try await analysis.export(clip, poses: poses, settings: .app, style: .near, to: folder)

    let written = try await Clip(url: video).frames()
    while try await written.next() != nil {}
    #expect((written.width, written.height) == (1080, 1080))
    #expect(written.count == poses.video.nFrames)
    let seconds = try await AVURLAsset(url: video).load(.duration).seconds
    #expect(abs(seconds - Double(poses.video.nFrames) / poses.video.fps) < 0.001)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    #expect(names == ["hips-low_frames.csv", "hips-low_push_ups.mp4", "hips-low_summary.csv", "reps.json", "summary.txt"])
}
