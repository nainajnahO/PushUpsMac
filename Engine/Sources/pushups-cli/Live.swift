import AVFoundation
import Foundation
import os
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
    /// Each rep as it was counted, when, and how long after its lockout frame arrived, seconds.
    var counted: [(rep: Rep, at: ContinuousClock.Instant, delay: Double)] = []
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
func playLive(_ url: URL, size: CGSize?, trim: Double?, settings: Settings, recorder: LiveRecorder? = nil,
              loops: Int = 1) async throws -> LiveRun {
    let poser = LivePoser()
    let camera = Task.detached(priority: .userInitiated) {
        try await deliver(url, size: size, trim: trim, loops: loops, to: poser, recording: recorder)
    }
    // A long session reports each minute: what Vision kept up with, the counter's slowest frame, and memory.
    var minute = (start: ContinuousClock.now, received: 0, posed: 0, vision: [Double](), delays: [Double](), slowest: 0.0)

    var run = LiveRun(set: LiveSet(settings: settings))
    for await frame in poser.frames {
        recorder?.append(frame.pose, at: frame.presentationTime)
        let adding = ContinuousClock.now
        let counted = run.set.add(frame)
        _ = run.set.overlay
        minute.slowest = max(minute.slowest, (ContinuousClock.now - adding) / .seconds(1))
        // The overlay is ready, and any rep counted: what the app's views draw next.
        let now = ContinuousClock.now
        run.delays.append((now - frame.arrived) / .seconds(1))
        for rep in counted { run.counted.append((rep, now, (now - run.set.arrivals[rep.lockoutFrame]) / .seconds(1))) }
        run.frames.append(frame)
        (run.width, run.height) = (frame.width, frame.height)
        minute.posed += 1
        minute.vision.append(frame.visionSeconds)
        minute.delays.append(run.delays.last ?? 0)
        if loops > 1, now - minute.start >= .seconds(60) {
            let received = poser.counts.received
            print("  minute \(fixed(frame.pose.time / 60, 1)): posed \(minute.posed) of \(received - minute.received) frames, "
                  + "Vision median \(fixed(median(minute.vision) * 1000, 1)) ms, frame to overlay median \(fixed(median(minute.delays) * 1000, 1)) ms, "
                  + "counter's slowest frame \(fixed(minute.slowest * 1000, 2)) ms, \(run.set.counter?.count ?? 0) reps, "
                  + "memory \(fixed(footprintMB(), 0)) MB")
            minute = (now, received, 0, [], [], 0)
        }
    }
    // The set ends with the clip: a rep still going counts now, if it's a push-up.
    let now = ContinuousClock.now
    for rep in run.set.finish() { run.counted.append((rep, now, (now - run.set.arrivals[rep.lockoutFrame]) / .seconds(1))) }
    let delivery = try await camera.value
    (run.received, run.dropped, run.failed, run.lastError) = poser.counts
    (run.lateness, run.span) = (delivery.lateness, delivery.span)
    return run
}

/// The camera's side of the stand-in: decodes the next frame, waits for its time, hands it over, and
/// ends the frames after the last. Returns how late each frame was handed over, and the frames' span.
/// With `loops` over 1, the clip plays that many times back to back, each time a frame after the last ended,
/// as one long session.
private func deliver(_ url: URL, size: CGSize?, trim: Double?, loops: Int, to poser: LivePoser,
                     recording recorder: LiveRecorder?) async throws -> (lateness: [Double], span: Double) {
    defer { poser.finish() }
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PosesError.noVideo(url) }
    var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    if let size {
        settings[kCVPixelBufferWidthKey as String] = Int(size.width)
        settings[kCVPixelBufferHeightKey as String] = Int(size.height)
    }
    let clock = ContinuousClock()
    var start: (pts: Double, clock: ContinuousClock.Instant)?
    var lateness: [Double] = [], span = 0.0
    var offset = CMTime.zero
    for _ in 0..<loops {
        let reader = try AVAssetReader(asset: asset)
        if let trim { reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: trim, preferredTimescale: 600)) }
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: settings))
        try reader.start()
        var (last, step) = (CMTime.zero, CMTime.zero)
        while let sample = try await provider.next() {
            guard var frame = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else { continue }
            (step, last) = (frame.presentationTimeStamp - last, frame.presentationTimeStamp)
            frame.presentationTimeStamp = frame.presentationTimeStamp + offset
            let pts = frame.presentationTimeStamp.seconds
            let origin = start ?? (pts, clock.now)
            start = origin
            let due = origin.clock + .seconds(pts - origin.pts)
            try await clock.sleep(until: due, tolerance: .zero)
            lateness.append((clock.now - due) / .seconds(1))
            // As the app's camera does: every frame into the recording, then Vision's turn.
            recorder?.append(frame)
            poser.receive(frame)
            span = pts - origin.pts
        }
        offset = offset + last + step
    }
    return (lateness, span)
}

/// The live run's numbers, one block, then the reps counted live; with `clip`, the same set's poses as the
/// app reads them from a clip (a golden poses JSON), counted, and counted on the live run's frames only.
@MainActor
func printLive(of url: URL, size: CGSize?, trim: Double?, settings: Settings, clip: URL?, speak: Bool,
               record: URL?, loops: Int) async throws {
    let recorder = try record.map { try LiveRecorder(url: $0) }
    let run = try await playLive(url, size: size, trim: trim, settings: settings, recorder: recorder, loops: loops)
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
    for (rep, _, delay) in run.counted {
        // Counted at the end of the set, not from the frames after its lockout.
        let atEnd = rep.lockoutFrame + RepCounter.framesAfterLockout >= counter.poses.count
        print("  rep \(rep.number) counted \(fixed(delay * 1000, 0)) ms after its lockout\(atEnd ? " (at the end of the set)" : ""): \(describe(rep))")
    }
    if speak { await printSpoken(run.counted) }
    if let recorder { try await printRoundTrip(recorder, run: run, counter: counter) }
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


/// What the app would say for each rep live, with cues, and how long it takes to say: each utterance
/// rendered to audio buffers by `AVSpeechSynthesizer.write`, never played. The app cuts a rep's words short
/// at once when the next rep is counted first.
@MainActor
func printSpoken(_ counted: [(rep: Rep, at: ContinuousClock.Instant, delay: Double)]) async {
    let synthesizer = AVSpeechSynthesizer()
    for (i, entry) in counted.enumerated() {
        let utterance = entry.rep.utterance(cues: true)
        let seconds = await spokenSeconds(utterance, by: synthesizer)
        var line = "  says “\(utterance.speechString)” (\(fixed(seconds, 2)) s, \(utterance.voice?.name ?? "the default voice"))"
        if i + 1 < counted.count {
            let gap = (counted[i + 1].at - entry.at) / .seconds(1)
            line += seconds > gap ? "; cut short: the next rep is counted \(fixed(gap, 2)) s later"
                : "; done \(fixed(gap - seconds, 2)) s before the next rep is counted"
        }
        print(line)
    }
}

/// How long `utterance` takes to say, from the audio `AVSpeechSynthesizer.write` renders it to. The
/// synthesizer calls back on its own thread, and ends with an empty buffer.
@MainActor
func spokenSeconds(_ utterance: AVSpeechUtterance, by synthesizer: AVSpeechSynthesizer) async -> Double {
    let total = OSAllocatedUnfairLock(initialState: (frames: 0.0, rate: 0.0, done: false))
    return await withCheckedContinuation { continuation in
        synthesizer.write(utterance) { @Sendable buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let (frames, rate) = (Double(pcm.frameLength), pcm.format.sampleRate)
            let finished: Double? = total.withLock { total in
                guard !total.done else { return nil }
                if frames == 0 {
                    total.done = true
                    return total.rate > 0 ? total.frames / total.rate : 0
                }
                total.frames += frames
                total.rate = rate
                return nil
            }
            if let finished { continuation.resume(returning: finished) }
        }
    }
}


/// The recording's round trip: written as the app writes it, then reopened as the app opens a clip, with its
/// recorded poses, and counted again; and, apart, Vision run afresh on the recorded video.
@MainActor
func printRoundTrip(_ recorder: LiveRecorder, run: LiveRun, counter live: RepCounter) async throws {
    let written = try await recorder.finish()
    let asset = AVURLAsset(url: recorder.url)
    let video = try await asset.loadTracks(withMediaType: .video).first
    let duration = try await video?.load(.timeRange).duration.seconds ?? 0
    let bytes = try recorder.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    print("  recorded \(recorder.url.lastPathComponent): \(written.frames) of \(run.received) frames (\(written.skipped) skipped by the encoder), "
          + "\(written.poses) of \(run.frames.count) poses, \(fixed(duration, 2)) s, \(fixed(Double(bytes) / 1_000_000, 1)) MB")
    guard let poses = try await Poses.recorded(in: recorder.url) else {
        print("  reopened: no recorded poses")
        return
    }
    let offsets = zip(poses.frames, run.frames).map { abs($0.time - $1.pose.time) }
    let jointsAlike = zip(poses.frames, run.frames).allSatisfy { $0.joints == $1.pose.joints }
    let reopened = RepCounter(poses: poses, settings: live.settings)
    print("  reopened: \(poses.frames.count) poses at \(poses.width) × \(poses.height), times within "
          + "\(fixed((offsets.max() ?? 0) * 1000, 3)) ms of live, joints \(jointsAlike ? "the same" : "different"); "
          + "\(summary(reopened)); \(reopened.reps == live.reps ? "every rep the same as live, to the frame" : compare(reopened.reps, live.reps))")
    let start = ContinuousClock.now
    let fresh = try await Poses.detect(in: recorder.url)
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    let afresh = RepCounter(poses: fresh, settings: live.settings)
    print("  Vision afresh on the recording, every frame (\(fresh.frames.count), \(fixed(seconds, 1)) s): \(summary(afresh)); \(compare(afresh.reps, live.reps)) against live")
}

/// The middle value of `values`, or 0 for none.
func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

/// The process's physical memory footprint, MB, as Activity Monitor's Memory column shows it. Foundation has no
/// API for it; Mach's `task_info` does.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}
