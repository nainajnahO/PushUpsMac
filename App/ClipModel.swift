import AVFoundation
import Observation
import OSLog
import PushUpsEngine

private let log = Logger(subsystem: "nainajnahO.PushUpsMac", category: "clip")

/// The open clip: its player, its poses (from Vision, once), and their reps, counted with the current
/// settings.
@Observable
final class ClipModel {
    private(set) var url: URL?
    private(set) var player: AVPlayer?
    private(set) var poses: Poses?
    private(set) var analysis: RepCounter?
    /// The counter's settings, from the sidebar: each change counts the poses again at once.
    var settings = Settings() {
        didSet { reanalyze() }
    }
    /// The frame on screen, for the overlay and the panel's playhead lines: AVFoundation calls back with
    /// the player's time once a frame while it plays, and on every seek or scrub, and not at all while
    /// it's paused, so nothing redraws a still frame (a `TimelineView` redrew both 60 times a second).
    let playhead = Playhead()
    /// The measured near side, or the whole skeleton.
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
                log.notice("player \(status == .playing ? "playing" : "paused", privacy: .public) at \(time, format: .fixed(precision: 2)) s, playhead on frame \(self.playhead.frame)")
            }
        }
        (poses, analysis, failure, progress, isPosing) = (nil, nil, nil, 0, true)
        playhead.frame = 0
        log.notice("opened \(url.lastPathComponent, privacy: .public)")
        posing = Task {
            let start = ContinuousClock.now
            do {
                let poses = try await engine.poses(of: url) { fraction in
                    Task { @MainActor in self.progress = fraction }
                }
                guard !Task.isCancelled else { return }
                log.notice("poses: \(poses.frames.count) frames in \((ContinuousClock.now - start) / .seconds(1), format: .fixed(precision: 1)) s")
                self.poses = poses
                isPosing = false
                reanalyze()
                // About a frame: the mean gap between the frames' presentation times.
                let times = poses.frames.map(\.time)
                let gap = times.count > 1 ? (times[times.count - 1] - times[0]) / Double(times.count - 1) : 1.0 / 30
                let frame = CMTime(seconds: gap, preferredTimescale: 600)
                ticks = player.addPeriodicTimeObserver(forInterval: frame, queue: .main) { [weak model = self] time in
                    MainActor.assumeIsolated { model?.follow(time) }
                }
                // From the first frame: the player sat about half a second in by now (0.2 to 0.8 s on
                // the test clips), so autoplay skipped the start.
                await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            } catch {
                guard !Task.isCancelled else { return }
                isPosing = false
                failure = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                log.error("\(self.failure ?? "", privacy: .public)")
            }
        }
    }

    /// The poses counted with the current settings, frame by frame as live: no Vision, so at once.
    func reanalyze() {
        guard let poses else { return }
        let start = ContinuousClock.now
        let analysis = RepCounter(poses: poses, settings: settings)
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
        guard let analysis else { return }
        let frame = analysis.frame(at: time.seconds)
        if frame != playhead.frame { playhead.frame = frame }
    }

    func importFailed(_ error: any Error) {
        failure = error.localizedDescription
    }
}

/// Runs Vision off the main actor, and keeps each clip's poses, so reopening a clip or changing a
/// setting never runs Vision again. A recorded live set brings its own poses, the ones it was counted
/// with live, so it reopens with the count and grades it had.
actor PoseEngine {
    private var cache: [URL: Poses] = [:]

    func poses(of url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Poses {
        if let poses = cache[url] { return poses }
        let poses = if let recorded = try await Poses.recorded(in: url) {
            recorded
        } else {
            try await Poses.detect(in: url, progress: progress)
        }
        cache[url] = poses
        return poses
    }
}
