import Foundation

// The near side's joints as geometry, as the demo's `src/form.py` reads them: the side, the
// shoulder's height above the wrist, the elbow angle and the body line. Filmed side-on, the far
// arm and leg hide behind the body and the model guesses them, so everything is read off one side.

/// Which side of the body the analysis reads.
public enum Side: String, Codable, Sendable, CaseIterable {
    case left, right
}

extension Side {
    /// The six joints the analysis reads on this side: shoulder, elbow, wrist, hip, knee, ankle.
    var joints: [JointName] {
        switch self {
        case .left: [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle]
        case .right: [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle]
        }
    }
}

/// The side whose arm and leg Vision is surer of over the clip, its confidences summed over every frame;
/// a tie is the left.
func pickSide(_ frames: [Pose], forced: Side? = nil) -> Side {
    if let forced { return forced }
    func total(_ side: Side) -> Double {
        frames.reduce(0) { sum, pose in side.joints.reduce(sum) { $0 + Double(pose.joints[$1]?.confidence ?? 0) } }
    }
    return total(.right) > total(.left) ? .right : .left
}

/// One side's joints per frame, in frame heights: x is scaled by the aspect ratio, so angles and lengths
/// are true shapes. NaN where Vision didn't see the joint, or anybody.
struct Joints {
    var shoulder: [SIMD2<Double>]
    var elbow: [SIMD2<Double>]
    var wrist: [SIMD2<Double>]
    var hip: [SIMD2<Double>]
    var knee: [SIMD2<Double>]
    var ankle: [SIMD2<Double>]

    init(_ frames: [Pose], side: Side, aspect: Double) {
        let columns = side.joints.map { name in
            frames.map { pose in
                pose.joints[name].map { SIMD2($0.location.x * aspect, $0.location.y) } ?? SIMD2(.nan, .nan)
            }
        }
        (shoulder, elbow, wrist, hip, knee, ankle) = (columns[0], columns[1], columns[2], columns[3], columns[4], columns[5])
    }
}

/// `np.linalg.norm` of a 2-vector: the square root of the sum of squares, as NumPy computes it
/// (not `hypot`, which scales first and can differ in the last bit).
private func norm(_ v: SIMD2<Double>) -> Double {
    (v.x * v.x + v.y * v.y).squareRoot()
}

/// The interior angle at `b`, degrees, per frame; NaN where any point is missing.
func angle(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>], _ c: [SIMD2<Double>]) -> [Double] {
    zip(a, zip(b, c)).map { a, bc in
        let (b, c) = bc
        let u = a - b, v = c - b
        let cosine = (u.x * v.x + u.y * v.y) / (norm(u) * norm(v))
        // np.clip keeps NaN; Swift's min and max would drop it.
        let clipped = cosine.isNaN ? cosine : Swift.min(1, Swift.max(-1, cosine))
        return acos(clipped) * (180 / .pi)
    }
}

/// Upper arm plus forearm, median over the clip, in frame heights: a limb's length doesn't
/// change, and one frame's misplaced wrist shouldn't rescale the whole signal.
func armLength(_ j: Joints) -> Double {
    let lengths = (0..<j.shoulder.count).map { norm(j.shoulder[$0] - j.elbow[$0]) + norm(j.elbow[$0] - j.wrist[$0]) }
    return median(lengths.filter(\.isFinite))
}

/// The shoulder's height above the wrist, in arm lengths: about 1 locked out, 0.2 chest down.
func shoulderHeight(_ j: Joints, arm: Double) -> [Double] {
    zip(j.wrist, j.shoulder).map { ($0.y - $1.y) / arm }
}

/// The hip's signed angle off the shoulder-ankle line, degrees: 0 is a straight plank, negative
/// the hips below the line (too low), positive above it (too high), whichever way the athlete faces.
func bodyLine(_ j: Joints) -> [Double] {
    let bend = angle(j.shoulder, j.hip, j.ankle).map { 180 - $0 }
    return (0..<bend.count).map { i in
        let (shoulder, hip, ankle) = (j.shoulder[i], j.hip[i], j.ankle[i])
        let t = (hip.x - ankle.x) / (shoulder.x - ankle.x)
        let lineY = ankle.y + t * (shoulder.y - ankle.y)
        // Image y grows downward, so a hip above the line has the smaller y. NaN compares false: -1.
        return bend[i] * (hip.y < lineY ? 1 : -1)
    }
}

/// `np.median`: the middle value, or the mean of the two middle ones; NaN for none.
func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}
