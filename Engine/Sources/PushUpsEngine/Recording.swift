import AVFoundation
import Synchronization

// A live set saved as it happens, to open afterwards as a clip with the poses it had live. Every camera frame
// goes into a QuickTime movie, and each posed frame's pose into a timed metadata track of the same movie, at
// the frame's time: AVFoundation's own way of carrying data frame by frame with a video. So a set is one
// file, which any player opens as a plain movie and which the sandbox lets the app read whole.

/// The metadata track's one item a posed frame: the joints as JSON text. QuickTime's "mdta" key space, as
/// `AVMetadataItem.identifier(forKey:keySpace:)` writes it.
let poseIdentifier = "mdta/nainajnahO.PushUpsMac.pose"

/// Records a live set: ``append(_:)`` every camera frame as it arrives, from the camera's queue, and
/// ``append(_:at:)`` each posed frame's pose; then ``finish()``. The first frame starts the movie, at its own
/// size, in HEVC.
public final class LiveRecorder: Sendable {
    public let url: URL

    public enum Failure: LocalizedError {
        case noFrames
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noFrames: "No frame came from the camera to record"
            case .failed(let reason): "The recording failed: \(reason)"
            }
        }
    }

    private struct State {
        let writer: AVAssetWriter
        var video: AVAssetWriterInput.SampleBufferReceiver?
        var poses: AVAssetWriterInput.MetadataReceiver?
        var frames = 0, skipped = 0, posed = 0
        var failure: String?
        var finished = false
    }

    private let state: Mutex<State>

    public init(url: URL) throws {
        self.url = url
        state = Mutex(State(writer: try AVAssetWriter(outputURL: url, fileType: .mov)))
    }

    /// A camera frame, in order. One the encoder isn't ready for is skipped and counted.
    public func append(_ frame: CMReadySampleBuffer<CVReadOnlyPixelBuffer>) {
        state.withLock { state in
            guard !state.finished, state.failure == nil else { return }
            do {
                if state.video == nil { try Self.start(&state, with: frame) }
                if try state.video?.appendImmediately(CMReadySampleBuffer(frame)) == true {
                    state.frames += 1
                } else {
                    state.skipped += 1
                }
            } catch {
                state.failure = error.localizedDescription
            }
        }
    }

    /// A posed frame's pose, at the frame's presentation time.
    public func append(_ pose: Pose, at time: CMTime) {
        let json: String
        do {
            json = String(decoding: try JSONEncoder().encode(pose.joints), as: UTF8.self)
        } catch {
            state.withLock { $0.failure = $0.failure ?? error.localizedDescription }
            return
        }
        state.withLock { state in
            guard !state.finished, state.failure == nil, let poses = state.poses else { return }
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: poseIdentifier)
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = json as NSString
            // No duration: each pose lasts until the next.
            let group = AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: time, duration: .invalid))
            do {
                if try poses.appendImmediately(group) { state.posed += 1 }
            } catch {
                state.failure = error.localizedDescription
            }
        }
    }

    /// Ends the movie. Frames and poses that come after are ignored. Returns how many frames and poses were
    /// written, and how many frames the encoder skipped.
    public func finish() async throws -> (frames: Int, poses: Int, skipped: Int) {
        let started = state.withLock { state in
            state.finished = true
            state.video?.finish()
            state.poses?.finish()
            return state.video != nil
        }
        guard started else { throw Failure.noFrames }
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            state.withLock { $0.writer.finishWriting { finished.resume() } }
        }
        return try state.withLock { state in
            if let failure = state.failure { throw Failure.failed(failure) }
            if state.writer.status != .completed {
                throw Failure.failed(state.writer.error?.localizedDescription ?? "status \(state.writer.status.rawValue)")
            }
            return (state.frames, state.posed, state.skipped)
        }
    }

    /// The movie's two tracks, the video's size taken from the first frame, and the session started at it.
    private static func start(_ state: inout State, with frame: CMReadySampleBuffer<CVReadOnlyPixelBuffer>) throws {
        let (width, height) = frame.content.withUnsafeBuffer { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let format = try CMFormatDescription(boxedMetadataSpecifications: [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: poseIdentifier as CFString,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_UTF8,
        ]])
        let poses = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        poses.addTrackAssociation(withTrackOf: video, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
        state.video = state.writer.inputReceiver(for: video)
        state.poses = state.writer.inputMetadataReceiver(for: poses)
        try state.writer.start()
        state.writer.startSession(atSourceTime: frame.presentationTimeStamp)
    }
}

extension Poses {
    /// The poses a live set was recorded with (``LiveRecorder``), timed as the movie plays; nil for a movie
    /// without them, such as a clip filmed on the phone.
    public static func recorded(in url: URL) async throws -> Poses? {
        let asset = AVURLAsset(url: url)
        var track: AVAssetTrack?
        for candidate in try await asset.loadTracks(withMediaType: .metadata) {
            let formats = try await candidate.load(.formatDescriptions)
            if formats.contains(where: { $0.identifiers.contains(poseIdentifier) }) {
                track = candidate
                break
            }
        }
        guard let track, let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await video.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputMetadataProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        try reader.start()
        var frames: [Pose] = []
        while let group = try await provider.next() {
            for item in group.items where item.identifier?.rawValue == poseIdentifier {
                guard let json = try await item.load(.stringValue) else { continue }
                let joints = try JSONDecoder().decode([JointName: Joint].self, from: Data(json.utf8))
                frames.append(Pose(time: group.timeRange.start.seconds, joints: joints))
            }
        }
        return Poses(source: url.lastPathComponent, width: Int(size.width), height: Int(size.height), frames: frames)
    }
}
