import Foundation

// Counting push-ups one frame at a time, the same way live and on a clip. The counter knows only the
// frames so far, plus five for smoothing (a sixth of a second at 30 fps). It finds the plank once you hold
// it, and measures your arm there, straight. It counts a rep when you go down and come back up, and times
// and grades the rep as it closes. A rep, once counted, never changes.

/// The settings the counter reads, in the sidebar.
public struct Settings: Sendable, Codable, Equatable {
    /// Which side to measure; nil picks the one Vision is surer of, up to the plank.
    public var side: Side?
    /// Which span the push-up time reports.
    public var metric = Metric.moving
    /// Down: the shoulder at most this many arm lengths above the wrist at the deepest point. Your planks
    /// read 0.97–0.98; your full reps' bottoms 0.34–0.58, the half rep's 0.63 (#57).
    public var romDownHeight = 0.60
    /// Up: the shoulder back to this share of the plank at lockout.
    public var romUpFraction = 0.90
    /// Straight back: every frame from descent to lockout within this many degrees of the line. 14°
    /// catches hips-low's rep 3, whose sag reads −15.8°.
    public var backToleranceDegrees = 14.0

    public init() {}
}

/// Which span a rep's push-up time is.
public enum Metric: String, Codable, Sendable, CaseIterable {
    /// Leaving the bottom to lockout, leaving out a pause on the floor.
    case moving
    /// The deepest point to lockout, the pause included.
    case ascent
}

/// One top-to-bottom-to-top cycle. Frames are positions in the clip's poses; times are their
/// presentation times, seconds.
public struct Rep: Sendable, Equatable {
    public var number: Int
    /// The descent starts.
    public var descentFrame: Int
    /// The deepest point, where the descent dies away.
    public var bottomFrame: Int
    /// The push starts: leaving the bottom.
    public var pushFrame: Int
    /// The push ends: arms straight, or where the set ended.
    public var lockoutFrame: Int
    public var descentTime: Double
    public var bottomTime: Double
    public var pushTime: Double
    public var lockoutTime: Double
    /// Arm lengths below the plank at the bottom of the cycle.
    public var depth: Double
    public var grade: Grade

    public var eccentricSeconds: Double { bottomTime - descentTime }
    /// Held at the bottom, between the descent dying away and the push starting.
    public var pauseSeconds: Double { max(0, pushTime - bottomTime) }
    public var concentricSeconds: Double { lockoutTime - pushTime }
    public var ascentSeconds: Double { lockoutTime - bottomTime }

    /// The push-up time `metric` reports.
    public func seconds(_ metric: Metric) -> Double {
        metric == .moving ? concentricSeconds : ascentSeconds
    }

    /// Full range of motion.
    public var complete: Bool { grade.complete }
    public var straight: Bool { grade.backOK }
}

/// The plank the counter measures against, found once you hold it.
public struct Plank: Sendable, Equatable {
    /// The frame the hold was found on.
    public var frame: Int
    /// The near arm, upper arm plus forearm, straight: frame heights. Every height is in these.
    public var arm: Double
    /// The shoulder's height above the wrist in the plank, arm lengths: about 1.
    public var level: Double
}

/// Counts push-ups from one frame's pose at a time: ``add(_:)`` each frame as it comes, then ``finish()``
/// when the set ends.
public struct RepCounter: Sendable {
    public let settings: Settings
    /// Width over height of the frames.
    let aspect: Double

    /// Every frame so far, and when each is shown.
    public private(set) var poses: [Pose] = []
    public private(set) var times: [Double] = []
    /// Fixed once the plank is found.
    public private(set) var side: Side?
    public private(set) var plank: Plank?
    /// The shoulder's height above the wrist, arm lengths, per frame: NaN until the plank is found (then
    /// filled in for the frames before it), and where Vision missed a joint.
    public private(set) var raw: [Double] = []
    /// The body line, signed degrees, per frame, NaN until the plank as `raw` is.
    public private(set) var line: [Double] = []
    /// The readings a grade takes: `raw` and `line` through a 5-frame median, so one bad pose can't decide
    /// a rep.
    public private(set) var heightReading: [Double] = []
    public private(set) var lineReading: [Double] = []
    /// What's counted: `heightReading` through a 5-frame mean. Shorter than `raw` by the frames it waits for.
    public private(set) var height: [Double] = []
    public private(set) var reps: [Rep] = []
    /// Once ``finish()`` has run, no frame is added.
    public private(set) var isFinished = false

    /// The cycle in progress: the top it started from, and once it's gone down, its bottom.
    private var start = 0
    private var bottom: Int?
    private var isBackUp = false
    /// The next frame the counting looks at: the first without its speed yet.
    private var next = 0

    // Constants, measured on the six test clips.
    /// The plank: the near arm at least this straight (degrees)...
    static let straightElbow = 140.0
    /// ...the body within this of level (degrees: 11–19° in your planks, 90° standing)...
    static let levelBody = 35.0
    /// ...held this long (seconds; you hold it 0.27–2 s before the first rep)...
    static let plankSeconds = 0.2
    /// ...with the shoulder moving less than this, in arm lengths.
    static let plankSteadiness = 0.1
    /// A rep starts once the shoulder is this far below the plank, arm lengths (your half rep: 0.34)...
    static let downDepth = 0.25
    /// ...and is back up once it's within this of the plank again.
    static let upDepth = 0.1
    /// A phase starts and ends where the shoulder's speed falls under this share of its fastest.
    static let speedFraction = 0.1
    /// Frames either side of each frame in the median and in the mean.
    static let reach = 2

    public init(settings: Settings, aspect: Double) {
        self.settings = settings
        self.aspect = aspect
    }

    /// Counts a whole clip: every frame, then the end of the set.
    public init(poses: Poses, settings: Settings) {
        self.init(settings: settings, aspect: poses.aspect)
        for pose in poses.frames { add(pose) }
        finish()
    }

    /// One more frame, in order.
    public mutating func add(_ pose: Pose) {
        precondition(!isFinished, "A finished set takes no more frames")
        poses.append(pose)
        times.append(pose.time)
        if plank == nil {
            raw.append(.nan)
            line.append(.nan)
            findPlank()
        } else {
            measure(poses.count - 1)
        }
        smooth(final: false)
    }

    /// The set has ended: the frames still waiting for smoothing are smoothed with what there is, and a rep
    /// still going counts if it's a push-up.
    public mutating func finish() {
        guard !isFinished else { return }
        isFinished = true
        smooth(final: true)
        guard let bottom else { return }
        let last = height.count - 1
        if isBackUp {
            close(bottom: bottom, lockout: last)
        } else if !(lineReading[last] < -settings.backToleranceDegrees) {
            // Not back up when the set ended. It counts, short, if you were still in a push-up; lying on the
            // floor and pushing up with the hips left down (more than the back tolerance below the line) isn't
            // one (#42).
            close(bottom: bottom, lockout: last)
        }
        self.bottom = nil
    }

    // MARK: The plank

    /// Looks for a plank held up to the newest frame: the arm straight, the body level and the shoulder
    /// steady, for `plankSeconds`. Once found, the side and the arm are fixed, and the frames so far measured.
    private mutating func findPlank() {
        let newest = poses.count - 1
        let side = settings.side ?? pickSide(poses[...])
        // From the latest frame at least `plankSeconds` before this one.
        guard let first = poses.lastIndex(where: { poses[newest].time - $0.time >= Self.plankSeconds }) else { return }
        let joints = poses[first...newest].map { NearSide($0, side: side, aspect: aspect) }
        guard joints.allSatisfy({ $0.elbowAngle >= Self.straightElbow && $0.tilt <= Self.levelBody }) else { return }
        let arm = median(joints.map(\.arm))
        let heights = joints.map { $0.shoulderHeight / arm }
        guard let low = heights.min(), let high = heights.max(), high - low <= Self.plankSteadiness else { return }
        self.side = side
        plank = Plank(frame: newest, arm: arm, level: median(heights))
        // Everything so far, measured now; the counting starts at the plank.
        for i in poses.indices { measure(i) }
        (start, next) = (newest, newest)
    }

    /// The shoulder's height and the body line on frame `i`, once the plank is known.
    private mutating func measure(_ i: Int) {
        guard let plank, let side else { return }
        let joints = NearSide(poses[i], side: side, aspect: aspect)
        let (height, bend) = (joints.shoulderHeight / plank.arm, joints.bodyLine)
        if i < raw.count {
            (raw[i], line[i]) = (height, bend)
        } else {
            raw.append(height)
            line.append(bend)
        }
    }

    // MARK: Smoothing, and counting each frame as it's smoothed

    /// Extends the readings and the counted height as far as the frames allow, then counts on every frame
    /// whose speed is known. `final`: no more frames will come, so the windows at the end take what there is.
    private mutating func smooth(final: Bool) {
        guard plank != nil else { return }
        let n = raw.count
        let r = Self.reach
        func window(_ i: Int, _ count: Int) -> ClosedRange<Int> { max(0, i - r)...min(count - 1, i + r) }
        while heightReading.count < n, final || heightReading.count + r < n {
            let i = heightReading.count
            heightReading.append(median(raw[window(i, n)]))
            lineReading.append(median(line[window(i, n)]))
        }
        while height.count < heightReading.count, final || height.count + r < heightReading.count {
            let w = heightReading[window(height.count, heightReading.count)].filter(\.isFinite)
            height.append(w.isEmpty ? .nan : w.reduce(0, +) / Double(w.count))
        }
        // A frame's speed needs the next frame's height.
        while next < height.count, final || next + 1 < height.count {
            count(next)
            next += 1
        }
    }

    /// The shoulder's speed on frame `i`, arm lengths per frame, positive going up: central differences,
    /// one-sided at the ends. Per frame, not per second: the edit list's first frame is shown for 5–22 ms.
    private func rise(_ i: Int) -> Double {
        let last = height.count - 1
        guard last > 0 else { return 0 }
        let (a, b) = (max(0, i - 1), min(last, i + 1))
        return (height[b] - height[a]) / Double(b - a)
    }

    /// One step of the counting, on frame `i`. Armed at the top; a rep once the shoulder is `downDepth` below
    /// the plank; back up within `upDepth` of it; closed where the push dies away.
    private mutating func count(_ i: Int) {
        guard let plank, height[i].isFinite else { return }
        let depth = plank.level - height[i]
        guard let bottom else {
            if !height[start].isFinite || height[i] > height[start] { start = i }
            if depth > Self.downDepth { self.bottom = i }
            return
        }
        if height[i] < height[bottom] { self.bottom = i }
        if depth < Self.upDepth { isBackUp = true }
        guard isBackUp else { return }
        // Lockout: from the push's fastest frame, the first whose speed has fallen under its share.
        let window = (self.bottom ?? bottom)...i
        let fastest = fastest(window, by: rise)
        let lockout = walk(rise, from: fastest, within: window, step: 1)
        if lockout < i || rise(i) <= Self.speedFraction * rise(fastest) {
            close(bottom: self.bottom ?? bottom, lockout: lockout)
            self.bottom = nil
            start = lockout
        }
    }

    /// Counts the rep from `start` through `bottom` to `lockout`: its phases, and its grade.
    private mutating func close(bottom: Int, lockout: Int) {
        guard let plank else { return }
        let push = walk(rise, from: fastest(bottom...lockout, by: rise), within: bottom...lockout, step: -1)
        let fall = { -self.rise($0) }
        let fastestDown = fastest(start...bottom, by: fall)
        let descent = walk(fall, from: fastestDown, within: start...bottom, step: -1)
        // The deepest point is where the descent dies away, not the noisiest low frame of a pause on the floor.
        let settle = walk(fall, from: fastestDown, within: start...bottom, step: 1)
        let low = min(settle, push)
        let grade = Grade(height: heightReading, line: lineReading, plank: plank.level, span: descent...lockout,
                          push: push...lockout, settings: settings)
        reps.append(Rep(number: reps.count + 1, descentFrame: descent, bottomFrame: low, pushFrame: push,
                        lockoutFrame: lockout, descentTime: times[descent], bottomTime: times[low],
                        pushTime: times[push], lockoutTime: times[lockout], depth: plank.level - height[bottom],
                        grade: grade))
        isBackUp = false
    }

    /// The first frame in `window` where `speed` is largest.
    private func fastest(_ window: ClosedRange<Int>, by speed: (Int) -> Double) -> Int {
        window.max { speed($0) < speed($1) }!
    }
}

/// From `peak`, steps to the first frame whose speed is at most `fraction` of the peak's, or stops at the
/// window's end.
func walk(_ speed: (Int) -> Double, from peak: Int, within window: ClosedRange<Int>, step: Int,
          fraction: Double = RepCounter.speedFraction) -> Int {
    let floor = fraction * speed(peak)
    var i = peak
    while window.contains(i + step) {
        i += step
        if speed(i) <= floor { break }
    }
    return i
}

extension RepCounter {
    public var count: Int { reps.count }

    /// The plank's level, arm lengths: NaN until it's found.
    public var top: Double { plank?.level ?? .nan }

    /// Full range, straight back, out of the reps so far.
    public var tally: (full: Int, straight: Int, graded: Int) {
        (reps.count(where: \.complete), reps.count(where: \.straight), reps.count)
    }

    /// Reps locked out by `frame`.
    public func done(at frame: Int) -> [Rep] {
        reps.filter { $0.lockoutFrame <= frame }
    }
}
