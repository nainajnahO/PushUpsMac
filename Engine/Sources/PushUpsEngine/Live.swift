import CoreMedia
import CoreVideo
import Synchronization
import Vision

// Vision on a camera's frames as they come, one at a time. A frame that comes while Vision is still on the
// one before is dropped, so the poses keep up with the camera rather than falling further behind it.
//
// Vision's own `VideoProcessor` only reads a file, so a camera's frames go through
// `DetectHumanBodyPoseRequest.perform(on:)` one by one. The dropping is ours rather than
// `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames`: that one drops a frame only while the camera's
// delegate is blocked, and the delegate has to return at once to hand every frame on (a recording takes them
// all, #25). It's the same code whether the frames come from a camera or from a clip played at its own pace.

/// One frame Vision posed, and when: what the live overlay and counter take.
public struct LiveFrame: Sendable {
    /// The athlete, timed in seconds from the first frame received.
    public var pose: Pose
    /// The frame as shown, in pixels: what the joints are normalized to.
    public var width: Int
    public var height: Int
    /// When the frame reached `receive(_:)`.
    public var arrived: ContinuousClock.Instant
    /// How long Vision took on it.
    public var visionSeconds: Double
}

/// Vision on camera frames: ``receive(_:)`` each frame as the camera delivers it, upright as it's shown, and
/// read the posed ones from ``frames``. Called from the camera's queue; it never blocks it. A camera's
/// `CMSampleBuffer` comes in as `CMReadySampleBuffer(unsafeWithPixelBuffer:)`, CoreMedia's `Sendable` form.
public final class LivePoser: Sendable {
    /// Every frame Vision posed, in order. Ends after ``finish()``, once Vision is done with the last one.
    public let frames: AsyncStream<LiveFrame>

    private struct State {
        var received = 0
        var dropped = 0
        var failed = 0
        var lastError: String?
        var busy = false
        var finished = false
        /// The first frame's presentation time: poses are timed from it.
        var start: CMTime?
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<LiveFrame>.Continuation
    private let request = DetectHumanBodyPoseRequest()

    public init() {
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Frames received, and how many of them were dropped because Vision was busy, or failed in Vision.
    public var counts: (received: Int, dropped: Int, failed: Int, lastError: String?) {
        state.withLock { ($0.received, $0.dropped, $0.failed, $0.lastError) }
    }

    /// A frame from the camera, as it arrives. Vision takes it if it's free, and returns at once either way.
    public func receive(_ frame: CMReadySampleBuffer<CVReadOnlyPixelBuffer>) {
        let arrived = ContinuousClock.now
        let time = frame.presentationTimeStamp
        let start: CMTime? = state.withLock { state in
            guard !state.finished else { return nil }
            state.received += 1
            guard !state.busy else {
                state.dropped += 1
                return nil
            }
            state.busy = true
            if state.start == nil { state.start = time }
            return state.start
        }
        guard let start else { return }
        Task {
            await pose(frame, time: (time - start).seconds, arrived: arrived)
        }
    }

    /// No more frames: ``frames`` ends once Vision is done with the frame it's on.
    public func finish() {
        let idle = state.withLock { state in
            state.finished = true
            return !state.busy
        }
        if idle { continuation.finish() }
    }

    private func pose(_ frame: CMReadySampleBuffer<CVReadOnlyPixelBuffer>, time: Double, arrived: ContinuousClock.Instant) async {
        let started = ContinuousClock.now
        // Vision takes a `CVPixelBuffer`, not the read-only one, and only reads it. The closure runs at once.
        nonisolated(unsafe) var pixels: CVPixelBuffer!
        frame.content.withUnsafeBuffer { pixels = $0 }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let size = CGSize(width: width, height: height)
        var joints: [JointName: Joint] = [:]
        do {
            let observations = try await request.perform(on: pixels, orientation: .up)
            // One athlete a frame: the largest person, as on a clip.
            if let athlete = observations.max(by: { area($0) < area($1) }) {
                joints = shownJoints(of: athlete, stored: size, transform: .identity, shown: CGRect(origin: .zero, size: size))
            }
        } catch {
            state.withLock { state in
                state.failed += 1
                state.lastError = error.localizedDescription
            }
        }
        let vision = (ContinuousClock.now - started) / .seconds(1)
        continuation.yield(LiveFrame(pose: Pose(time: time, joints: joints), width: width, height: height,
                                     arrived: arrived, visionSeconds: vision))
        let finished = state.withLock { state in
            state.busy = false
            return state.finished
        }
        if finished { continuation.finish() }
    }
}

/// A set counted live: each posed frame into the counter a clip goes through, as it comes. Nothing re-runs
/// over the frames so far; a rep is counted once the smoothing has the five frames after its lockout.
public struct LiveSet: Sendable {
    public let settings: Settings
    /// Nil until the first frame, whose shape the counter measures in.
    public private(set) var counter: RepCounter?
    /// When each frame reached the poser, by its place in the counter's poses: how long after its lockout a
    /// rep is counted.
    public private(set) var arrivals: [ContinuousClock.Instant] = []

    public init(settings: Settings) {
        self.settings = settings
    }

    /// The next posed frame, in order. Returns the reps it counted, usually none.
    public mutating func add(_ frame: LiveFrame) -> ArraySlice<Rep> {
        var counter = counter ?? RepCounter(settings: settings, aspect: Double(frame.width) / Double(frame.height))
        let before = counter.reps.count
        counter.add(frame.pose)
        arrivals.append(frame.arrived)
        self.counter = counter
        return counter.reps[before...]
    }

    /// The set has ended. Returns the rep still going, if it counts.
    public mutating func finish() -> ArraySlice<Rep> {
        guard var counter, !counter.isFinished else { return [] }
        let before = counter.reps.count
        counter.finish()
        self.counter = counter
        return counter.reps[before...]
    }

    /// The overlay on the newest frame: before the plank, the joints with the body line drawn straight.
    public var overlay: OverlayFrame? {
        guard let counter, !counter.poses.isEmpty else { return nil }
        return counter.overlay(atFrame: counter.poses.count - 1, tolerance: settings.backToleranceDegrees)
    }

    /// The same frames counted with `settings`, as a setting changed mid-set. Still going: not finished.
    public func recounted(with settings: Settings) -> LiveSet {
        var set = LiveSet(settings: settings)
        guard let counter else { return set }
        set.counter = RepCounter(settings: settings, aspect: counter.aspect)
        for pose in counter.poses { set.counter?.add(pose) }
        set.arrivals = arrivals
        return set
    }
}
