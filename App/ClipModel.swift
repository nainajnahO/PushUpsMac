import AVFoundation
import Observation
import OSLog
import PushUpsEngine

private let log = Logger(subsystem: "nainajnahO.PushUpsMac", category: "clip")

/// The open clip: its player, its poses (from Vision, once), and the analysis of them with the
/// current settings.
@Observable
final class ClipModel {
    private(set) var url: URL?
    private(set) var player: AVPlayer?
    private(set) var poses: Poses?
    private(set) var analysis: RepAnalysis?
    /// The analysis's settings, from the sidebar: each change re-grades at once, from the same poses.
    var settings = Settings.app {
        didSet { reanalyze() }
    }
    /// The source frame on screen, for the overlay and the panel: AVFoundation calls back with the
    /// player's time once a frame while it plays, and on every seek or scrub, and not at all while
    /// it's paused, so nothing redraws a still frame (a `TimelineView` redrew both 60 times a second).
    private(set) var playhead = 0
    /// The demo's `OVERLAY`: the measured near side, or the whole skeleton.
    var overlayStyle = OverlayStyle.near
    /// Of the poses, 0 to 1, while Vision runs.
    private(set) var progress = 0.0
    private(set) var isPosing = false
    private(set) var failure: String?
    var isImporting = false

    private let engine = PoseEngine()
    private var posing: Task<Void, Never>?
    private var playback: NSKeyValueObservation?
    private var ticks: Any?
    private var scopedURL: URL?

    /// The window's subtitle: what's happening, or the result.
    var status: String {
        if let failure { return failure }
        if isPosing { return "Finding the body… \(Int(progress * 100)) %" }
        guard let analysis else { return url == nil ? "" : "Opening…" }
        let (full, straight, graded) = analysis.tally
        let reps = analysis.count == 1 ? "1 rep" : "\(analysis.count) reps"
        return graded > 0 ? "\(reps) · \(full)/\(graded) full range · \(straight)/\(graded) straight back" : reps
    }

    /// Opens a clip: plays it once its poses are in. `securityScoped` for a URL from the open panel or
    /// a drop, whose access the sandbox grants only while it's held.
    func open(_ url: URL, securityScoped: Bool = false) {
        posing?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = securityScoped && url.startAccessingSecurityScopedResource() ? url : nil
        self.url = url
        if let ticks { self.player?.removeTimeObserver(ticks) }
        ticks = nil
        let player = AVPlayer(url: url)
        self.player = player
        playback = player.observe(\.timeControlStatus) { player, _ in
            let status = player.timeControlStatus
            let time = player.currentTime().seconds
            Task { @MainActor in
                log.notice("player \(status == .playing ? "playing" : "paused", privacy: .public) at \(time, format: .fixed(precision: 2)) s, playhead on frame \(self.playhead)")
            }
        }
        (poses, analysis, failure, progress, isPosing, playhead) = (nil, nil, nil, 0, true, 0)
        log.notice("opened \(url.lastPathComponent, privacy: .public)")
        posing = Task {
            let start = ContinuousClock.now
            do {
                let poses = try await engine.poses(of: url) { fraction in
                    Task { @MainActor in self.progress = fraction }
                }
                guard !Task.isCancelled else { return }
                log.notice("poses: \(poses.video.nFrames) frames in \((ContinuousClock.now - start) / .seconds(1), format: .fixed(precision: 1)) s")
                self.poses = poses
                isPosing = false
                reanalyze()
                let frame = CMTime(seconds: 1 / poses.video.fps, preferredTimescale: 600)
                ticks = player.addPeriodicTimeObserver(forInterval: frame, queue: .main) { [weak model = self] time in
                    MainActor.assumeIsolated { model?.follow(time) }
                }
                player.play()
            } catch {
                guard !Task.isCancelled else { return }
                isPosing = false
                failure = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                log.error("\(self.failure ?? "", privacy: .public)")
            }
        }
    }

    /// The analysis of the poses with the current settings: no Vision, so at once.
    func reanalyze() {
        guard let poses else { return }
        let start = ContinuousClock.now
        let analysis = analyze(poses, settings: settings)
        self.analysis = analysis
        let (full, straight, graded) = analysis.tally
        log.notice("\(analysis.count) reps, \(full)/\(graded) full range, \(straight)/\(graded) straight back, in \((ContinuousClock.now - start) / .milliseconds(1), format: .fixed(precision: 1)) ms")
    }

    /// Shows the rep from where it starts going down.
    func jump(to rep: RepRow) {
        player?.seek(to: CMTime(seconds: rep.startSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        log.notice("jumped to rep \(rep.id) at \(rep.startSeconds, format: .fixed(precision: 2)) s")
    }

    private func follow(_ time: CMTime) {
        guard let analysis, let poses else { return }
        let frame = analysis.sourceFrame(at: time.seconds, fps: poses.video.fps)
        if frame != playhead { playhead = frame }
    }

    func importFailed(_ error: any Error) {
        failure = error.localizedDescription
    }
}

/// Runs Vision off the main actor, and keeps each clip's poses, so reopening a clip or changing a
/// setting never runs Vision again.
actor PoseEngine {
    private var cache: [URL: Poses] = [:]

    func poses(of url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Poses {
        if let poses = cache[url] { return poses }
        let clip = try await Clip(url: url)
        let expected = max(1, clip.duration * clip.nominalFrameRate)
        let poses = try await Poses.detect(in: clip) { frame in progress(min(1, Double(frame + 1) / expected)) }
        cache[url] = poses
        return poses
    }
}
