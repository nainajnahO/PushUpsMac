import CoreImage
import Foundation
import Vision

/// The 17 COCO keypoints, in the order the demo's gateway returns them (`KPT_NAMES`).
public let cocoJoints = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
]

/// A clip's poses in the shape the demo's gateway replies with, so the demo's Python runs on them
/// unchanged, plus the frames' rate and size (`video`).
///
/// Keypoints are normalized to the frame, origin top-left with y down, `(0, 0)` for a joint the
/// model didn't see; scores are the model's confidence per joint.
public struct Poses: Codable, Sendable {
    public var video: Video
    public var content: Content

    public struct Video: Codable, Sendable {
        /// What the frames are timed by: frame index / fps.
        public var fps: Double
        /// The size of the frames the model saw.
        public var width: Int
        public var height: Int
        public var nFrames: Int
        /// The clip's file name.
        public var source: String
        /// The pose model, and the milliseconds it took per frame.
        public var model: String?
        public var msPerFrame: Double?

        enum CodingKeys: String, CodingKey {
            case fps, width, height, nFrames = "n_frames", source, model, msPerFrame = "ms_per_frame"
        }

        public init(fps: Double, width: Int, height: Int, nFrames: Int, source: String, model: String? = nil,
                    msPerFrame: Double? = nil) {
            (self.fps, self.width, self.height, self.nFrames) = (fps, width, height, nFrames)
            (self.source, self.model, self.msPerFrame) = (source, model, msPerFrame)
        }
    }

    public struct Content: Codable, Sendable {
        public var object = "vid.pose.kpts"
        public var kptsLabels = cocoJoints
        /// Every frame, as `{"frame_id": n}`: a frame without a person is a gap, not a missing frame.
        public var frames: [FrameID]
        public var items: [Person]

        enum CodingKeys: String, CodingKey {
            case object, kptsLabels = "kpts_labels", frames, items
        }
    }

    public struct FrameID: Codable, Sendable {
        public var frameID: Int
        enum CodingKeys: String, CodingKey { case frameID = "frame_id" }
    }

    public struct Person: Codable, Sendable, Equatable {
        public var frameID: Int
        /// 17 `[x, y]`, normalized, y down; `[0, 0]` unseen.
        public var keypoints: [[Double]]
        public var scores: [Double]
        /// `[x, y, width, height]`, normalized.
        public var box: [Double]

        enum CodingKeys: String, CodingKey {
            case frameID = "frame_id", keypoints = "kpts_xy", scores = "kpts_score", box = "bbox_xywh"
        }

        public init(frameID: Int, keypoints: [[Double]], scores: [Double], box: [Double]) {
            self.frameID = frameID
            self.keypoints = keypoints
            self.scores = scores
            self.box = box
        }
    }

    public init(video: Video, frames: Int, persons: [Person]) {
        self.video = video
        content = Content(frames: (0..<frames).map { FrameID(frameID: $0) }, items: persons)
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Poses.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)
    }

    /// The persons on each frame, by frame index.
    public var byFrame: [[Person]] {
        var frames = [[Person]](repeating: [], count: video.nFrames)
        for person in content.items where frames.indices.contains(person.frameID) {
            frames[person.frameID].append(person)
        }
        return frames
    }
}

/// The demo's `PRECISION`: the gateway rounds normalized coordinates and scores to 4 decimals.
func rounded(_ value: Double) -> Double {
    (value * 10_000).rounded() / 10_000
}

/// Vision's joints for each COCO keypoint.
private let visionJoints: [HumanBodyPoseObservation.JointName] = [
    .nose, .leftEye, .rightEye, .leftEar, .rightEar,
    .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
    .leftWrist, .rightWrist, .leftHip, .rightHip,
    .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
]

/// Apple Vision's body pose on one frame, as the gateway's persons: every person Vision finds.
///
/// Vision's points have their origin bottom-left; the gateway's (and the body line's sign) top-left.
/// A joint Vision doesn't return, or returns with confidence 0, is the `(0, 0)` sentinel. Every
/// other joint is kept with its confidence, as the gateway keeps ViTPose's every joint: the demo
/// thresholds nothing, and only sums the scores to pick the side.
public func detectPersons(in image: CIImage, frame: Int) async throws -> [Poses.Person] {
    let observations = try await DetectHumanBodyPoseRequest().perform(on: image)
    return observations.map { observation in
        let joints = observation.allJoints()
        var keypoints: [[Double]] = []
        var scores: [Double] = []
        for name in visionJoints {
            if let joint = joints[name], joint.confidence > 0 {
                keypoints.append([rounded(joint.location.x), rounded(1 - joint.location.y)])
                scores.append(rounded(Double(joint.confidence)))
            } else {
                keypoints.append([0, 0])
                scores.append(0)
            }
        }
        return Poses.Person(frameID: frame, keypoints: keypoints, scores: scores, box: box(around: keypoints))
    }
}

/// The box around the seen joints (Vision gives no person box), `[x, y, width, height]`.
func box(around keypoints: [[Double]]) -> [Double] {
    let seen = keypoints.filter { $0 != [0, 0] }
    guard let first = seen.first else { return [0, 0, 0, 0] }
    var (x0, y0, x1, y1) = (first[0], first[1], first[0], first[1])
    for point in seen {
        x0 = min(x0, point[0]); x1 = max(x1, point[0])
        y0 = min(y0, point[1]); y1 = max(y1, point[1])
    }
    return [x0, y0, rounded(x1 - x0), rounded(y1 - y0)]
}

/// The demo's `dedupe`: on each frame, the persons that best overlap the previous frame's kept
/// person come first, then the larger; a person overlapping a kept one by `iou` or more is the same
/// one; `maxPersons` are kept (the demo keeps one athlete).
public func dedupe(_ frames: [[Poses.Person]], maxPersons: Int = 1, iou threshold: Double = 0.6) -> [[Poses.Person]] {
    var previous: [Double]?
    return frames.map { persons in
        guard !persons.isEmpty else { return persons }
        // Python's `sorted` is stable, as is this: equal keys keep the model's order.
        let order = persons.enumerated().sorted { a, b in
            let keyA = (-(previous.map { iou(a.element.box, $0) } ?? 0), -area(a.element.box))
            let keyB = (-(previous.map { iou(b.element.box, $0) } ?? 0), -area(b.element.box))
            return keyA != keyB ? keyA < keyB : a.offset < b.offset
        }.map(\.element)
        var kept: [Poses.Person] = []
        for person in order where kept.allSatisfy({ iou(person.box, $0.box) < threshold }) {
            kept.append(person)
        }
        kept = Array(kept.prefix(maxPersons))
        if let first = kept.first { previous = first.box }
        return kept
    }
}

func area(_ box: [Double]) -> Double {
    box[2] * box[3]
}

/// Intersection over union of two `[x, y, width, height]` boxes.
func iou(_ a: [Double], _ b: [Double]) -> Double {
    let x0 = max(a[0], b[0]), y0 = max(a[1], b[1])
    let x1 = min(a[0] + a[2], b[0] + b[2]), y1 = min(a[1] + a[3], b[1] + b[3])
    let inter = max(0, x1 - x0) * max(0, y1 - y0)
    let union = a[2] * a[3] + b[2] * b[3] - inter
    return union > 0 ? inter / union : 0
}

extension Poses {
    /// Vision's body pose on every frame of `clip`, read at `height` up to `trim` seconds, one
    /// athlete per frame (``dedupe(_:maxPersons:iou:)``). `progress` hears each frame done.
    public static func detect(in clip: Clip, height: Int? = 1080, trim: Double? = nil,
                              progress: @Sendable (Int) -> Void = { _ in }) async throws -> Poses {
        let frames = try await clip.frames(height: height, trim: trim)
        var found: [[Person]] = []
        var visionTime = Duration.zero
        while let frame = try await frames.next() {
            let start = ContinuousClock.now
            found.append(try await detectPersons(in: frame.image, frame: frame.index))
            visionTime += ContinuousClock.now - start
            progress(frame.index)
        }
        let video = Video(fps: frames.fps, width: frames.width, height: frames.height, nFrames: frames.count,
                          source: clip.url.lastPathComponent, model: "Apple Vision DetectHumanBodyPoseRequest",
                          msPerFrame: found.isEmpty ? nil : visionTime / .milliseconds(1) / Double(found.count))
        return Poses(video: video, frames: frames.count, persons: dedupe(found).flatMap { $0 })
    }
}
