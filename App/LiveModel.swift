import AVFoundation
import Observation
import OSLog
import PushUpsEngine
import SwiftUI

nonisolated private let log = Logger(subsystem: "nainajnahO.PushUpsMac", category: "live")

/// The live set: Vision's poses on the camera's frames as they come, counted by the counter a clip goes
/// through, and the overlay on the newest.
@Observable
final class LiveModel {
    /// The overlay on the newest posed frame.
    private(set) var overlay: OverlayFrame?
    /// That frame as shown, in pixels.
    private(set) var frameSize = CGSize.zero
    /// Frames posed a second, over the last second.
    private(set) var posedPerSecond: Double?
    /// The set so far, for the sidebar and the panel: refreshed as each rep is counted and twice a second,
    /// not on every frame, so the charts aren't rebuilt 30 times a second.
    private(set) var shown: RepCounter?
    /// Say each rep's number as it's counted, and with `speaksCues`, what fell short.
    var speaksCount = true
    var speaksCues = true
    /// Record each set: the camera's video and its poses, saved to Movies › PushUpsMac, to open as a clip
    /// once the camera is off.
    var records = true
    /// Ending the set: the last posed frames going in and the recording being written.
    private(set) var isStopping = false
    /// Why the last set wasn't recorded, if it wasn't.
    private(set) var recordingFailure: String?

    @ObservationIgnored private var set = LiveSet(settings: PushUpsEngine.Settings())
    @ObservationIgnored private var lastShown = ContinuousClock.now
    @ObservationIgnored private var poser: LivePoser?
    @ObservationIgnored private var recorder: LiveRecorder?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var timings = Timings()
    @ObservationIgnored private let speaker = Speaker()

    /// A new set, counted with `settings` and, with `records`, recorded: where the camera's frames go.
    func start(settings: PushUpsEngine.Settings) -> (poser: LivePoser, recorder: LiveRecorder?) {
        let poser = LivePoser()
        self.poser = poser
        recorder = records ? makeRecorder() : nil
        set = LiveSet(settings: settings)
        timings = Timings()
        if speaksCount { speaker.warmUp() }
        reading = Task { [weak self] in
            for await frame in poser.frames { self?.take(frame) }
        }
        log.notice("live set started")
        return (poser, recorder)
    }

    /// A recorder for the set, into Movies › PushUpsMac, named for when it starts, as QuickTime names its
    /// recordings.
    private func makeRecorder() -> LiveRecorder? {
        let folder = URL.moviesDirectory.appending(component: "PushUpsMac", directoryHint: .isDirectory)
        let name = "Push-ups \(Date.now.formatted(Self.fileDate)).mov"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recorder = try LiveRecorder(url: folder.appending(component: name))
            recordingFailure = nil
            log.notice("recording to \(recorder.url.path(percentEncoded: false), privacy: .public)")
            return recorder
        } catch {
            recordingFailure = "Couldn't record the set: \(error.localizedDescription)"
            log.error("couldn't record: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// "2026-11-04 at 22.31.05", in the Mac's time zone.
    private static let fileDate = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian))

    /// A setting changed mid-set: the frames so far counted again with it, as on a clip.
    func recount(with settings: PushUpsEngine.Settings) {
        guard poser != nil, settings != set.settings else { return }
        set = set.recounted(with: settings)
        shown = set.counter
        log.notice("counted again with the new settings: \(self.set.counter?.count ?? 0) reps")
    }

    /// The camera is off: that's the end of the set, once Vision is done with the frame it's on. Returns the
    /// recording, written, if there is one.
    func stop() async -> URL? {
        guard let poser, !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }
        poser.finish()
        // The last posed frames, counted and recorded.
        await reading?.value
        (self.poser, reading) = (nil, nil)
        for rep in set.finish() {
            log.notice("rep \(rep.number) counted as the set ended: \(rep.grade.reason, privacy: .public), \(rep.grade.backLabel, privacy: .public)")
            say(rep)
        }
        if let counter = set.counter {
            let (full, straight, graded) = counter.tally
            log.notice("set: \(counter.count) reps, \(full)/\(graded) full range, \(straight)/\(graded) straight back")
        }
        (overlay, posedPerSecond, shown) = (nil, nil, nil)
        let (received, dropped, failed, lastError) = poser.counts
        log.notice("live set stopped: \(received) frames received, \(dropped) dropped while Vision was busy, \(failed) failed\(lastError.map { " (\($0))" } ?? "", privacy: .public)")
        guard let recorder else { return nil }
        self.recorder = nil
        do {
            let (frames, poses, skipped) = try await recorder.finish()
            log.notice("recorded \(frames) frames (\(skipped) skipped by the encoder) and \(poses) poses to \(recorder.url.lastPathComponent, privacy: .public)")
            return recorder.url
        } catch LiveRecorder.Failure.noFrames {
            // The camera never delivered a frame (no access, or no camera): nothing to record, and no file.
            return nil
        } catch {
            recordingFailure = "Couldn't record the set: \(error.localizedDescription)"
            log.error("recording failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func take(_ frame: LiveFrame) {
        guard let poser else { return }
        recorder?.append(frame.pose, at: frame.presentationTime)
        let counted = set.add(frame)
        overlay = set.overlay
        frameSize = CGSize(width: frame.width, height: frame.height)
        // The overlay is ready, and any rep counted: the views draw them next.
        let now = ContinuousClock.now
        timings.add(frame, delay: (now - frame.arrived) / .seconds(1), received: poser.counts.received)
        for rep in counted {
            let delay = (now - set.arrivals[rep.lockoutFrame]) / .milliseconds(1)
            log.notice("rep \(rep.number) counted \(delay, format: .fixed(precision: 0)) ms after its lockout: \(rep.grade.reason, privacy: .public), \(rep.grade.backLabel, privacy: .public)")
            say(rep)
        }
        if !counted.isEmpty || now - lastShown >= .milliseconds(500) {
            shown = set.counter
            lastShown = now
        }
        if let rate = timings.secondElapsed() { posedPerSecond = rate }
        if let summary = timings.summaryDue() { log.notice("\(summary, privacy: .public)") }
    }
}

/// Says the rep, if the count is spoken.
extension LiveModel {
    private func say(_ rep: Rep) {
        guard speaksCount else { return }
        let utterance = rep.utterance(cues: speaksCues)
        speaker.say(utterance)
        log.notice("said “\(utterance.speechString, privacy: .public)”")
    }
}

/// The spoken count: AVFoundation's speech synthesizer. A rep counted while the last is still being said
/// cuts it short, so the number is never late. At once, not at the next word: on macOS 27.2
/// `stopSpeaking(at: .word)` returns true and lets the words play to their end.
private final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    /// Loads the voice before the first rep, silently: rendered to buffers, not played. Said cold, the first
    /// rep's number starts about 0.9 s late; warmed up, 0.3 s.
    func warmUp() {
        synthesizer.write(AVSpeechUtterance(count: "1")) { @Sendable _ in }
    }

    func say(_ utterance: AVSpeechUtterance) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
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
