import AVFoundation
import Foundation
import PushUpsEngine

// A stand-in for the camera, for measuring the live path without one: a clip's frames handed to
// `LivePoser.receive(_:)` one at a time, each at its presentation time on the wall clock, from a thread of
// their own, whether or not Vision is ready for them. Only the CLI has it; the app takes its frames from
// the camera.

/// "1920x1080" as a size.
func frameSize(_ text: String) -> CGSize {
    let parts = text.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { usage() }
    return CGSize(width: parts[0], height: parts[1])
}

/// What a live run measured.
struct LiveRun {
    var frames: [LiveFrame] = []
    /// From each frame's arrival to its overlay being ready, on the main actor, seconds.
    var delays: [Double] = []
    /// How late each frame was handed over, against its presentation time, seconds.
    var lateness: [Double] = []
    var received = 0, dropped = 0, failed = 0
    var lastError: String?
    var width = 0, height = 0
    /// The clip's frames' span, seconds.
    var span = 0.0
}

/// Plays the clip at `url` into the live path at its own pace: decoded to the 8-bit 4:2:0 frames a camera
/// delivers, at `size` if given. The overlay is built on the main actor for each posed frame, as the app does.
@MainActor
func playLive(_ url: URL, size: CGSize?, trim: Double?) async throws -> LiveRun {
    let poser = LivePoser()
    let camera = Task.detached(priority: .userInitiated) { try await deliver(url, size: size, trim: trim, to: poser) }

    var run = LiveRun()
    var recent: [Pose] = []
    for await frame in poser.frames {
        recent.append(frame.pose)
        if recent.count > 60 { recent.removeFirst() }
        let overlay = OverlayFrame(pose: frame.pose, side: Side.picked(over: recent[...]))
        // The overlay is ready: what the app's view draws next.
        run.delays.append((ContinuousClock.now - frame.arrived) / .seconds(1))
        _ = overlay
        run.frames.append(frame)
        (run.width, run.height) = (frame.width, frame.height)
    }
    let delivery = try await camera.value
    (run.received, run.dropped, run.failed, run.lastError) = poser.counts
    (run.lateness, run.span) = (delivery.lateness, delivery.span)
    return run
}

/// The camera's side of the stand-in: decodes the next frame, waits for its time, hands it over, and
/// ends the frames after the last. Returns how late each frame was handed over, and the frames' span.
private func deliver(_ url: URL, size: CGSize?, trim: Double?,
                     to poser: LivePoser) async throws -> (lateness: [Double], span: Double) {
    defer { poser.finish() }
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PosesError.noVideo(url) }
    let reader = try AVAssetReader(asset: asset)
    if let trim { reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: trim, preferredTimescale: 600)) }
    var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    if let size {
        settings[kCVPixelBufferWidthKey as String] = Int(size.width)
        settings[kCVPixelBufferHeightKey as String] = Int(size.height)
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    let provider = reader.outputProvider(for: output)
    try reader.start()

    let clock = ContinuousClock()
    var start: (pts: Double, clock: ContinuousClock.Instant)?
    var lateness: [Double] = [], span = 0.0
    while let sample = try await provider.next() {
        guard let frame = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else { continue }
        let pts = frame.presentationTimeStamp.seconds
        let origin = start ?? (pts, clock.now)
        start = origin
        let due = origin.clock + .seconds(pts - origin.pts)
        try await clock.sleep(until: due, tolerance: .zero)
        lateness.append((clock.now - due) / .seconds(1))
        poser.receive(frame)
        span = pts - origin.pts
    }
    return (lateness, span)
}

/// The live run's numbers, one block.
@MainActor
func printLive(of url: URL, size: CGSize?, trim: Double?) async throws {
    let run = try await playLive(url, size: size, trim: trim)
    let fps = Double(run.received - 1) / run.span
    let posedFPS = Double(run.frames.count - 1) / run.span
    func ms(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "none" }
        let at = { (q: Double) in sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] * 1000 }
        return "median \(fixed(at(0.5), 1)), p95 \(fixed(at(0.95), 1)), max \(fixed(at(1), 1)) ms"
    }
    print("""
        \(url.lastPathComponent) live at \(run.width) × \(run.height), \(fixed(fps, 2)) fps: \(run.received) frames \
        over \(fixed(run.span, 2)) s, \(run.frames.count) posed (\(fixed(posedFPS, 2)) fps), \(run.dropped) dropped \
        (\(fixed(100 * Double(run.dropped) / Double(run.received), 1)) %), \(run.failed) failed\(run.lastError.map { " (\($0))" } ?? "")
          Vision per frame: \(ms(run.frames.map(\.visionSeconds)))
          arrival to overlay ready: \(ms(run.delays))
          frames handed over late by: \(ms(run.lateness))
          a person on \(run.frames.count { !$0.pose.joints.isEmpty }) of \(run.frames.count) posed frames
        """)
}
