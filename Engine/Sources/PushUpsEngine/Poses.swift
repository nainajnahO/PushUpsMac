import AVFoundation
import Vision

/// Vision's names for the body's joints ("leftShoulder", "rightAnkle", …).
public typealias JointName = HumanBodyPoseObservation.JointName

// So a pose's joints encode as a JSON object keyed by name, not as an array of alternating names and joints.
extension HumanBodyPoseObservation.JointName: @retroactive CodingKeyRepresentable {}

/// One joint Vision found on a frame.
public struct Joint: Codable, Sendable, Equatable {
    /// Where, normalized to the frame as it's shown: origin top-left, y down, as SwiftUI draws.
    public var location: CGPoint
    /// Vision's confidence, above 0.
    public var confidence: Float

    public init(location: CGPoint, confidence: Float) {
        self.location = location
        self.confidence = confidence
    }
}

/// The athlete on one frame: when the frame is shown, and the joints Vision found on them.
public struct Pose: Codable, Sendable, Equatable {
    /// The frame's presentation time, seconds from the start of the clip.
    public var time: Double
    /// By name; a joint Vision didn't see is missing, and a frame without anybody has none.
    public var joints: [JointName: Joint]

    public init(time: Double, joints: [JointName: Joint]) {
        self.time = time
        self.joints = joints
    }
}

/// A clip's poses, one per frame Vision analysed, and the size its frames are shown at.
public struct Poses: Codable, Sendable {
    /// The clip's file name.
    public var source: String
    /// The frame as shown, in pixels: what the joints are normalized to.
    public var width: Int
    public var height: Int
    public var frames: [Pose]

    public init(source: String, width: Int, height: Int, frames: [Pose]) {
        (self.source, self.width, self.height, self.frames) = (source, width, height, frames)
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Poses.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Whole or not at all: a write cut short leaves the file as it was.
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Width over height of the frame as shown.
    public var aspect: Double { Double(width) / Double(height) }
}

public enum PosesError: Error, CustomStringConvertible {
    case noVideo(URL)

    public var description: String {
        switch self {
        case .noVideo(let url): "\(url.lastPathComponent) has no video track"
        }
    }
}

extension Poses {
    /// Vision's body pose on every frame of the clip at `url`, up to `trim` seconds, read by Vision's own
    /// `VideoProcessor`. `progress` hears how far through the clip it is, 0 to 1.
    ///
    /// `VideoProcessor` hands Vision each frame as it's stored, without the track's `preferredTransform`,
    /// so the joints are turned into the frame as it's shown here. It reports a frame without anybody
    /// with no time, so such a frame is timed between its neighbours (``evenlyTimed(_:fallbackGap:)``).
    public static func detect(in url: URL, trim: Double? = nil,
                              progress: @Sendable (Double) -> Void = { _ in }) async throws -> Poses {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PosesError.noVideo(url) }
        let (stored, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = if let trim { trim } else { try await asset.load(.duration).seconds }
        let shown = CGRect(origin: .zero, size: stored).applying(transform)

        let processor = VideoProcessor(url)
        let results = try await processor.addRequest(DetectHumanBodyPoseRequest())
        processor.startAnalysis(of: trim.map { CMTimeRange(start: .zero, duration: CMTime(seconds: $0, preferredTimescale: 600)) })
        var times: [Double?] = []
        var joints: [[JointName: Joint]] = []
        for try await observations in results {
            // One athlete a frame: the largest person.
            let athlete = observations.max { area($0) < area($1) }
            let time = athlete?.timeRange?.start.seconds
            times.append(time)
            joints.append(athlete.map { shownJoints(of: $0, stored: stored, transform: transform, shown: shown) } ?? [:])
            if let time { progress(min(1, time / duration)) }
        }
        let frames = zip(evenlyTimed(times, fallbackGap: duration / Double(max(1, times.count))), joints).map(Pose.init)
        return Poses(source: url.lastPathComponent, width: Int(shown.width.rounded()), height: Int(shown.height.rounded()),
                     frames: frames)
    }
}

/// The joints Vision saw (confidence above 0), turned from the stored frame into the shown one by the track's
/// `preferredTransform` (pixels, y down), and normalized to it.
func shownJoints(of observation: HumanBodyPoseObservation, stored: CGSize, transform: CGAffineTransform,
                 shown: CGRect) -> [JointName: Joint] {
    var joints: [JointName: Joint] = [:]
    for (name, joint) in observation.allJoints() where joint.confidence > 0 {
        let point = joint.location.toImageCoordinates(stored, origin: .upperLeft).applying(transform)
        let location = CGPoint(x: (point.x - shown.minX) / shown.width, y: (point.y - shown.minY) / shown.height)
        joints[name] = Joint(location: location, confidence: joint.confidence)
    }
    return joints
}

/// The area of the box around the joints Vision saw, in the stored frame's normalized units. Vision's body
/// pose has no box of its own; Create ML Components' `PoseSelector` picks the largest one, but only from its
/// own `Pose`, built from the older `VNRecognizedPointsObservation`.
func area(_ observation: HumanBodyPoseObservation) -> Double {
    let points = observation.allJoints().values.filter { $0.confidence > 0 }.map(\.location)
    guard let first = points.first else { return 0 }
    var (x0, y0, x1, y1) = (first.x, first.y, first.x, first.y)
    for point in points {
        (x0, x1) = (min(x0, point.x), max(x1, point.x))
        (y0, y1) = (min(y0, point.y), max(y1, point.y))
    }
    return Double((x1 - x0) * (y1 - y0))
}

/// Every frame's time, from the times of the frames that have one: a run without times between two known
/// ones is spread evenly between them; one at either end steps by the gap next to it, or by `fallbackGap`
/// when fewer than two frames have a time.
func evenlyTimed(_ times: [Double?], fallbackGap: Double) -> [Double] {
    let known = times.indices.filter { times[$0] != nil }
    guard let first = known.first, let last = known.last else {
        return times.indices.map { Double($0) * fallbackGap }
    }
    let gap = { (a: Int, b: Int) in (times[b]! - times[a]!) / Double(b - a) }
    let startGap = known.count > 1 ? gap(first, known[1]) : fallbackGap
    let endGap = known.count > 1 ? gap(known[known.count - 2], last) : fallbackGap
    var result = [Double](repeating: 0, count: times.count)
    var next = 0   // the position in `known` of the first known index at or after i
    for i in times.indices {
        while next < known.count, known[next] < i { next += 1 }
        if let time = times[i] {
            result[i] = time
        } else if i < first {
            result[i] = times[first]! - Double(first - i) * startGap
        } else if i > last {
            result[i] = times[last]! + Double(i - last) * endGap
        } else {
            let (a, b) = (known[next - 1], known[next])
            result[i] = times[a]! + Double(i - a) * gap(a, b)
        }
    }
    return result
}
