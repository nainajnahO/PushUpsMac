import AVFoundation
import Observation
import OSLog
import PushUpsEngine
import SwiftUI

nonisolated private let log = Logger(subsystem: "nainajnahO.PushUpsMac", category: "live")

/// The live set: Vision's poses on the camera's frames as they come, and the overlay on the newest.
@Observable
final class LiveModel {
    /// The overlay on the newest posed frame.
    private(set) var overlay: OverlayFrame?
    /// That frame as shown, in pixels.
    private(set) var frameSize = CGSize.zero
    /// Frames posed a second, over the last second.
    private(set) var posedPerSecond: Double?

    @ObservationIgnored private var poser: LivePoser?
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// The last two seconds or so of poses, for the side Vision is surer of.
    @ObservationIgnored private var recent: [Pose] = []
    @ObservationIgnored private var timings = Timings()

    /// A new set: the sink the camera's frames go to.
    func start() -> LivePoser {
        stop()
        let poser = LivePoser()
        self.poser = poser
        timings = Timings()
        reading = Task { [weak self] in
            for await frame in poser.frames { self?.take(frame) }
        }
        log.notice("live set started")
        return poser
    }

    /// The camera is off: Vision finishes the frame it's on, and that's the end of the set.
    func stop() {
        guard let poser else { return }
        poser.finish()
        self.poser = nil
        (overlay, posedPerSecond, recent) = (nil, nil, [])
        let (received, dropped, failed, lastError) = poser.counts
        log.notice("live set stopped: \(received) frames received, \(dropped) dropped while Vision was busy, \(failed) failed\(lastError.map { " (\($0))" } ?? "", privacy: .public)")
    }

    private func take(_ frame: LiveFrame) {
        guard let poser else { return }
        recent.append(frame.pose)
        if recent.count > 60 { recent.removeFirst() }
        overlay = OverlayFrame(pose: frame.pose, side: Side.picked(over: recent[...]))
        frameSize = CGSize(width: frame.width, height: frame.height)
        // The overlay is ready: the view draws it next.
        timings.add(frame, delay: (ContinuousClock.now - frame.arrived) / .seconds(1), received: poser.counts.received)
        if let rate = timings.secondElapsed() { posedPerSecond = rate }
        if let summary = timings.summaryDue() { log.notice("\(summary, privacy: .public)") }
    }
}

/// The live path's numbers, for the log every five seconds and the subtitle every second: frames posed and
/// received, Vision's time per frame, and the delay from a frame arriving to its overlay being ready.
private struct Timings {
    private var vision: [Double] = [], delays: [Double] = []
    private var posed = 0, receivedAtStart: Int?, received = 0
    private var summaryStart = ContinuousClock.now
    private var second = (start: ContinuousClock.now, posed: 0)

    mutating func add(_ frame: LiveFrame, delay: Double, received: Int) {
        vision.append(frame.visionSeconds)
        delays.append(delay)
        posed += 1
        second.posed += 1
        if receivedAtStart == nil { receivedAtStart = received - 1 }
        self.received = received
    }

    /// Frames posed a second, once a second has gone by.
    mutating func secondElapsed() -> Double? {
        let elapsed = (ContinuousClock.now - second.start) / .seconds(1)
        guard elapsed >= 1 else { return nil }
        defer { second = (ContinuousClock.now, 0) }
        return Double(second.posed) / elapsed
    }

    /// The last five seconds, once they've gone by.
    mutating func summaryDue() -> String? {
        let elapsed = (ContinuousClock.now - summaryStart) / .seconds(1)
        guard elapsed >= 5 else { return nil }
        let frames = received - (receivedAtStart ?? received)
        defer { self = Timings(receivedAtStart: received) }
        return "posed \(posed) of \(frames) frames in \(fixed(elapsed, 1)) s (\(fixed(Double(posed) / elapsed, 1)) of "
            + "\(fixed(Double(frames) / elapsed, 1)) fps); Vision \(milliseconds(vision)); frame to overlay \(milliseconds(delays))"
    }

    private init(receivedAtStart: Int) {
        self.receivedAtStart = receivedAtStart
    }

    init() {}

    private func milliseconds(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "–" }
        let at = { (q: Double) in sorted[Int((Double(sorted.count - 1) * q).rounded())] * 1000 }
        return "median \(fixed(at(0.5), 1)) ms, p95 \(fixed(at(0.95), 1)) ms"
    }

    private func fixed(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// The overlay on the live picture, in the rectangle the frame fills (aspect fit, as the preview shows it).
struct LiveOverlay: View {
    let live: LiveModel
    let style: OverlayStyle

    var body: some View {
        GeometryReader { geometry in
            if let overlay = live.overlay, live.frameSize != .zero {
                let rect = AVMakeRect(aspectRatio: live.frameSize, insideRect: CGRect(origin: .zero, size: geometry.size))
                OverlayView(frame: overlay, style: style)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }
}
