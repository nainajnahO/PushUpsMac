import Foundation

// The near side's joints as geometry, one frame at a time: the arm's length, the elbow, the shoulder's
// height above the wrist, the body line, and how level the body lies. Filmed side-on, the far arm and leg
// hide behind the body and Vision guesses them, so everything is read off one side.

/// Which side of the body the analysis reads.
enum Side: Sendable {
    case left, right

    /// The six joints the analysis reads on this side: shoulder, elbow, wrist, hip, knee, ankle.
    var joints: [JointName] {
        switch self {
        case .left: [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle]
        case .right: [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle]
        }
    }
}

/// Vision's confidence in each side's arm and leg, summed over the frames so far. Summed as each frame comes,
/// so picking the side doesn't go back over every frame: before the plank, a live set picks it on every frame.
struct SideConfidence {
    private var left = 0.0, right = 0.0

    mutating func add(_ pose: Pose) {
        left = Side.left.joints.reduce(left) { $0 + Double(pose.joints[$1]?.confidence ?? 0) }
        right = Side.right.joints.reduce(right) { $0 + Double(pose.joints[$1]?.confidence ?? 0) }
    }

    /// The side Vision is surer of; a tie is the left.
    var surer: Side { right > left ? .right : .left }
}

/// One side's joints on one frame, in frame heights: x is scaled by the aspect ratio, so angles and
/// lengths are true shapes. NaN where Vision didn't see the joint, so whatever needs it reads NaN too.
struct NearSide {
    var shoulder, elbow, wrist, hip, knee, ankle: SIMD2<Double>

    init(_ pose: Pose, side: Side, aspect: Double) {
        let points = side.joints.map { name in
            pose.joints[name].map { SIMD2($0.location.x * aspect, $0.location.y) } ?? SIMD2(.nan, .nan)
        }
        (shoulder, elbow, wrist, hip, knee, ankle) = (points[0], points[1], points[2], points[3], points[4], points[5])
    }

    /// Upper arm plus forearm, frame heights.
    var arm: Double { length(shoulder - elbow) + length(elbow - wrist) }

    /// The elbow's interior angle, degrees: about 160° and over with the arm straight, as Vision places it.
    var elbowAngle: Double { angle(shoulder, elbow, wrist) }

    /// The shoulder's height above the wrist, frame heights (image y grows downward).
    var shoulderHeight: Double { wrist.y - shoulder.y }

    /// The hip's signed angle off the shoulder-ankle line, degrees: 0 is a straight plank, negative the hips
    /// below the line (too low), positive above it (too high), whichever way the athlete faces.
    var bodyLine: Double {
        let bend = 180 - angle(shoulder, hip, ankle)
        let t = (hip.x - ankle.x) / (shoulder.x - ankle.x)
        let lineY = ankle.y + t * (shoulder.y - ankle.y)
        // A hip above the line has the smaller y. NaN compares false: -1, and the bend is NaN anyway.
        return bend * (hip.y < lineY ? 1 : -1)
    }

    /// How far the shoulder-to-ankle line is off level, degrees: about 15° in a plank on the floor, 90° standing.
    var tilt: Double {
        let d = ankle - shoulder
        return abs(atan2(d.y, abs(d.x))) * 180 / .pi
    }
}

private func length(_ v: SIMD2<Double>) -> Double {
    (v.x * v.x + v.y * v.y).squareRoot()
}

/// The interior angle at `b`, degrees; NaN where any point is missing.
func angle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
    let u = a - b, v = c - b
    let cosine = (u.x * v.x + u.y * v.y) / (length(u) * length(v))
    // Keep NaN: Swift's min and max would drop it.
    return cosine.isNaN ? .nan : acos(min(1, max(-1, cosine))) * 180 / .pi
}

/// The middle value, or the mean of the two middle ones, of the finite values; NaN for none.
func median(_ values: some Sequence<Double>) -> Double {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return .nan }
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}
