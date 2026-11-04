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
    /// The set as the app counts it live.
    var set: LiveSet
    /// Each rep as it was counted, and how long after its lockout frame arrived, seconds.
    var counted: [(rep: Rep, delay: Double)] = []
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
/// delivers, at `size` if given. Each posed frame is counted and its overlay built on the main actor, as the
/// app does, and the set finished after the last.
@MainActor
func playLive(_ url: URL, size: CGSize?, trim: Double?, settings: Settings) async throws -> LiveRun {
    let poser = LivePoser()
    let camera = Task.detached(priority: .userInitiated) { try await deliver(url, size: size, trim: trim, to: poser) }

    var run = LiveRun(set: LiveSet(settings: settings))
    for await frame in poser.frames {
        let counted = run.set.add(frame)
        _ = run.set.overlay
        // The overlay is ready, and any rep counted: what the app's views draw next.
        let now = ContinuousClock.now
        run.delays.append((now - frame.arrived) / .seconds(1))
        for rep in counted { run.counted.append((rep, (now - run.set.arrivals[rep.lockoutFrame]) / .seconds(1))) }
        run.frames.append(frame)
        (run.width, run.height) = (frame.width, frame.height)
    }
    // The set ends with the clip: a rep still going counts now, if it's a push-up.
    let now = ContinuousClock.now
    for rep in run.set.finish() { run.counted.append((rep, (now - run.set.arrivals[rep.lockoutFrame]) / .seconds(1))) }
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

/// The live run's numbers, one block, then the reps counted live; with `clip`, the same set's poses as the
/// app reads them from a clip (a golden poses JSON), counted, and counted on the live run's frames only.
@MainActor
func printLive(of url: URL, size: CGSize?, trim: Double?, settings: Settings, clip: URL?) async throws {
    let run = try await playLive(url, size: size, trim: trim, settings: settings)
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
    guard let counter = run.set.counter else { return }
    print("  counted live: \(summary(counter))")
    for (rep, delay) in run.counted {
        // Counted at the end of the set, not from the frames after its lockout.
        let atEnd = rep.lockoutFrame + RepCounter.framesAfterLockout >= counter.poses.count
        print("  rep \(rep.number) counted \(fixed(delay * 1000, 0)) ms after its lockout\(atEnd ? " (at the end of the set)" : ""): \(describe(rep))")
    }
    guard let clip else { return }
    let poses = try Poses(contentsOf: clip)
    let whole = RepCounter(poses: poses, settings: settings)
    print("  the clip: \(summary(whole)); \(compare(counter.reps, whole.reps))")
    // The clip's own poses, but only on the frames the live run posed: what the drops alone change.
    let milliseconds = { (time: Double) in Int((time * 1000).rounded()) }
    let kept = Set(run.frames.map { milliseconds($0.pose.time + (poses.frames.first?.time ?? 0)) })
    let thinned = Poses(source: poses.source, width: poses.width, height: poses.height,
                        frames: poses.frames.filter { kept.contains(milliseconds($0.time)) })
    let dropped = RepCounter(poses: thinned, settings: settings)
    print("  the clip on the live run's \(thinned.frames.count) of \(poses.frames.count) frames: \(summary(dropped)); \(compare(dropped.reps, whole.reps))")
    for rep in whole.reps { print("    clip rep \(rep.number): \(describe(rep))") }
}

/// "4 reps, 4/4 full range, 4/4 straight back".
func summary(_ counter: RepCounter) -> String {
    let (full, straight, graded) = counter.tally
    return "\(counter.count) reps, \(full)/\(graded) full range, \(straight)/\(graded) straight back"
}

/// A rep's grade, with its readings.
func describe(_ rep: Rep) -> String {
    let grade = rep.grade
    return "\(grade.reason) (bottom \(fixed(grade.bottomHeight, 3)), top \(fixed(grade.topHeight, 2)) of \(fixed(grade.topRequired, 2))), "
        + "\(grade.backLabel) (\(fixed(grade.backWorst, 1))°)"
}

/// Whether two sets graded alike rep by rep: the count, and each rep's range and back.
func compare(_ reps: [Rep], _ other: [Rep]) -> String {
    guard reps.count == other.count else { return "a different count" }
    let differing = zip(reps, other).filter { $0.grade.reason != $1.grade.reason || $0.grade.backLabel != $1.grade.backLabel }
    return differing.isEmpty ? "the same count and grades" : "rep \(differing.map { String($0.0.number) }.joined(separator: ", ")) graded differently"
}
