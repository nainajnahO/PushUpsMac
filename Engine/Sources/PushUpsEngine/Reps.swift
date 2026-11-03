import Foundation

// Rep counting and each rep's phases, as the demo's `src/reps.py` does them. A push-up starts at
// the top, so the signal counted on is depth: how far the shoulder has come down from the plank,
// in arm lengths.

/// The settings the analysis reads, with the demo's `config.py` values as ``demo``.
public struct Settings: Sendable, Codable, Equatable {
    /// Which side to measure; nil picks the one that scores higher (`SIDE = "auto"`).
    public var side: Side?
    public var smoothMedianFrames = 5
    public var smoothMeanFrames = 5
    /// The plank, the relative zero: this percentile of the smoothed height.
    public var topPercentile = 90.0
    /// Down past this share of the typical depth confirms a rep...
    public var repPeakFraction = 0.50
    /// ...and back within this share of the top closes it.
    public var repResetFraction = 0.20
    /// A phase starts and ends where the speed falls under this share of its fastest.
    public var concentricVelocityFraction = 0.10

    public static let demo = Settings()
}

/// One top-to-bottom-to-top cycle. Frames are source frames; times are seconds (frame / fps).
public struct Rep: Sendable, Equatable {
    public var number: Int
    /// The descent starts.
    public var descentFrame: Int
    /// The deepest point, where the descent dies away.
    public var bottomFrame: Int
    /// The push starts: leaving the bottom.
    public var pushFrame: Int
    /// The push ends: arms straight.
    public var lockoutFrame: Int
    public var descentTime: Double
    public var bottomTime: Double
    public var pushTime: Double
    public var lockoutTime: Double
    /// Arm lengths below the plank at the bottom of the cycle.
    public var depth: Double

    public var eccentricSeconds: Double { bottomTime - descentTime }
    /// Held at the bottom, between the descent dying away and the push starting.
    public var pauseSeconds: Double { max(0, pushTime - bottomTime) }
    public var concentricSeconds: Double { lockoutTime - pushTime }
    public var ascentSeconds: Double { lockoutTime - bottomTime }
}

/// The analysis of a clip: every per-frame series, the levels, and the reps.
public struct RepAnalysis: Sendable {
    /// The source frame of each returned frame; every series is indexed like these.
    public var indices: [Int]
    public var times: [Double]
    public var side: Side
    /// Arm length, frame heights.
    public var arm: Double
    /// Shoulder height above the wrist, arm lengths: as measured, and smoothed.
    public var raw: [Double]
    public var height: [Double]
    /// The plank: the relative zero for depth.
    public var top: Double
    /// Body line, signed degrees.
    public var line: [Double]
    /// Near elbow, degrees: reported beside the grade, not graded.
    public var elbow: [Double]
    public var reps: [Rep]

    public var count: Int { reps.count }
}

/// The demo's `analyze`: builds the depth signal, counts reps off it and times each one's phases.
public func analyze(_ poses: Poses, settings: Settings = .demo) -> RepAnalysis {
    let (indices, frames) = poses.unwrapped()
    let times = indices.map { Double($0) / poses.video.fps }
    let side = pickSide(frames, forced: settings.side)
    let joints = Joints(frames, side: side, aspect: Double(poses.video.width) / Double(poses.video.height))
    let arm = armLength(joints)
    let raw = shoulderHeight(joints, arm: arm)
    let line = bodyLine(joints)
    let elbow = angle(joints.shoulder, joints.elbow, joints.wrist)

    let height = boxFilter(medianFilter(fillGaps(raw), settings.smoothMedianFrames), settings.smoothMeanFrames)
    let top = height.isEmpty ? 0 : percentile(height, settings.topPercentile)
    let depth = height.map { top - $0 }
    let amplitude = robustDepth(depth)
    // The shoulder's signed vertical speed, arm lengths per frame: positive going up.
    let rise = height.count > 2 ? gradient(height) : [Double](repeating: 0, count: height.count)
    let fall = rise.map { -$0 }
    let fraction = settings.concentricVelocityFraction

    let cycles = repCycles(depth, amplitude: amplitude, settings: settings)
    var reps: [Rep] = []
    for (n, (start, bottom)) in cycles.enumerated() {
        // The push's window runs to the next rep's bottom; its lockout is the top reached before then.
        let next = n + 1 < cycles.count ? cycles[n + 1].bottom : height.count - 1
        let topIndex = bottom + argmax(height[bottom...next])
        let fastestUp = bottom + argmax(rise[bottom...topIndex])
        let push = walk(rise, from: fastestUp, within: bottom...topIndex, step: -1, fraction: fraction)
        let lockout = walk(rise, from: fastestUp, within: bottom...topIndex, step: 1, fraction: fraction)
        let fastestDown = start + argmax(fall[start...bottom])
        let descent = walk(fall, from: fastestDown, within: start...bottom, step: -1, fraction: fraction)
        // The deepest point is where the descent dies away, not the noisiest low frame of a pause
        // on the floor: the pause belongs between it and the push.
        let settle = walk(fall, from: fastestDown, within: start...bottom, step: 1, fraction: fraction)
        let low = min(settle, push)
        reps.append(Rep(number: n + 1,
                        descentFrame: indices[descent], bottomFrame: indices[low],
                        pushFrame: indices[push], lockoutFrame: indices[lockout],
                        descentTime: times[descent], bottomTime: times[low],
                        pushTime: times[push], lockoutTime: times[lockout],
                        depth: depth[bottom]))
    }
    return RepAnalysis(indices: indices, times: times, side: side, arm: arm, raw: raw, height: height, top: top,
                       line: line, elbow: elbow, reps: reps)
}

/// The demo's `_cycles`: each rep's (start, bottom) by hysteresis. Armed near the top, confirmed
/// once the shoulder has come down past a share of the typical depth, closed when it comes back up
/// near the top. A clip that ends mid-rep closes it where it stops.
func repCycles(_ depth: [Double], amplitude: Double, settings: Settings) -> [(start: Int, bottom: Int)] {
    guard amplitude > 0 else { return [] }
    let high = settings.repPeakFraction * amplitude, low = settings.repResetFraction * amplitude
    var cycles: [(start: Int, bottom: Int)] = []
    var down = false, start = 0, bottom = 0
    for (i, d) in depth.enumerated() {
        if !down {
            if d < depth[start] { start = i }
            if d > high { (down, bottom) = (true, i) }
        } else {
            if d > depth[bottom] { bottom = i }
            if d < low {
                cycles.append((start, bottom))
                (down, start) = (false, i)
            }
        }
    }
    if down { cycles.append((start, bottom)) }
    return cycles
}

/// The demo's `_walk`: from `peak`, step to the first frame whose speed is at most `fraction` of the
/// peak's, or stop at the window's end.
func walk(_ speed: [Double], from peak: Int, within window: ClosedRange<Int>, step: Int, fraction: Double) -> Int {
    let floor = fraction * speed[peak]
    var i = peak
    while window.contains(i + step) {
        i += step
        if speed[i] <= floor { break }
    }
    return i
}

/// `np.argmax`: the offset of the first largest value (or of the first NaN) in `values`.
func argmax(_ values: ArraySlice<Double>) -> Int {
    var best = values.startIndex
    for i in values.indices {
        if values[i].isNaN { return i - values.startIndex }
        if values[i] > values[best] { best = i }
    }
    return best - values.startIndex
}

/// `np.gradient` with unit spacing: central differences inside, one-sided at the ends.
func gradient(_ f: [Double]) -> [Double] {
    f.indices.map { i in
        switch i {
        case 0: (f[1] - f[0]) / 1
        case f.count - 1: (f[i] - f[i - 1]) / 1
        default: (f[i + 1] - f[i - 1]) / 2
        }
    }
}
