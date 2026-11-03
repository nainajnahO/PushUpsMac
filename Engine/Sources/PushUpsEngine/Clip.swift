import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A clip's video track, read the way the demo's ffmpeg conversion reads it: every frame the clip
/// shows, in order, scaled to a height, and HDR tone-mapped to SDR, as 8-bit BGRA.
///
/// AVFoundation does the work: the decoder scales, and converts HLG or PQ to Rec. 709 when asked for
/// Rec. 709 colours, in place of the demo's ffmpeg scale filter and libplacebo tone mapping.
public struct Clip: Sendable {
    public let url: URL
    /// The size the frames are stored at, before ``orientation``.
    public let storedWidth: Int
    public let storedHeight: Int
    /// How the stored frames turn to be shown: the track's `preferredTransform`.
    public let orientation: CGImagePropertyOrientation
    /// HLG or PQ.
    public let isHDR: Bool
    /// AVFoundation's frame rate for the track. Not the one the analysis uses: see ``Frames/fps``.
    public let nominalFrameRate: Double
    public let duration: Double
    private let asset: AVURLAsset
    private let trackID: CMPersistentTrackID

    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipError.noVideo(url)
        }
        let (size, transform, rate, characteristics) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .mediaCharacteristics)
        self.url = url
        self.asset = asset
        trackID = track.trackID
        storedWidth = Int(size.width)
        storedHeight = Int(size.height)
        orientation = Clip.orientation(of: transform)
        isHDR = characteristics.contains(.containsHDRVideo)
        nominalFrameRate = Double(rate)
        duration = try await asset.load(.duration).seconds
    }

    /// Clockwise degrees the stored frames turn to be shown: 0, 90, 180 or 270.
    public var rotation: Int {
        switch orientation {
        case .right: 90
        case .down: 180
        case .left: 270
        default: 0
        }
    }

    /// The size the clip is shown at.
    public var width: Int { rotation % 180 == 0 ? storedWidth : storedHeight }
    public var height: Int { rotation % 180 == 0 ? storedHeight : storedWidth }

    /// The shown size scaled to `height`, only ever down, with an even width: ffmpeg's
    /// `scale=-2:'min(height,ih)'`, as the demo converts for the model (1080).
    public func size(height target: Int?) -> (width: Int, height: Int) {
        guard let target, target < height else { return (width, height) }
        let scaled = Double(width) * Double(target) / Double(height)
        return (Int((scaled / 2).rounded()) * 2, target)
    }

    /// The frames, scaled to `height` (shown size) and up to `trim` seconds, as ffmpeg's `-t` keeps them.
    public func frames(height: Int? = nil, trim: Double? = nil) async throws -> Frames {
        guard let track = try await asset.loadTrack(withTrackID: trackID) else { throw ClipError.noVideo(url) }
        return try Frames(clip: self, asset: asset, track: track, size: size(height: height), trim: trim)
    }

    /// iPhone clips turn by a multiple of 90°; mirrored transforms aren't made by a camera.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch Int((atan2(transform.b, transform.a) * 180 / .pi).rounded()) {
        case 90: .right
        case 180, -180: .down
        case -90: .left
        default: .up
        }
    }
}

public enum ClipError: Error, CustomStringConvertible {
    case noVideo(URL)
    case unreadable(URL, (any Error)?)

    public var description: String {
        switch self {
        case .noVideo(let url): "\(url.lastPathComponent) has no video track"
        case .unreadable(let url, let error):
            "\(url.lastPathComponent) couldn't be read: \(error.map { "\($0)" } ?? "unknown error")"
        }
    }
}

/// One frame the clip shows: its index among them, its presentation time, and its pixels as shown
/// (turned by the clip's orientation).
public struct Frame: Sendable {
    public let index: Int
    public let time: Double
    public let image: CIImage
}

/// Reads a clip's frames one at a time, in order.
public final class Frames {
    public let clip: Clip
    /// The shown size of each frame.
    public let width: Int
    public let height: Int
    private let reader: AVAssetReader
    private let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    private let trim: Double?
    private var times: [Double] = []
    private var pending: Frame?
    /// The first frame, left out when the clip's edit list cuts into it (see ``next()``).
    public private(set) var skipped = 0

    init(clip: Clip, asset: AVAsset, track: AVAssetTrack, size: (width: Int, height: Int), trim: Double?) throws {
        self.clip = clip
        (width, height) = size
        self.trim = trim
        let stored = clip.rotation % 180 == 0 ? size : (size.height, size.width)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: stored.0,
            kCVPixelBufferHeightKey as String: stored.1,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        reader = try AVAssetReader(asset: asset)
        if let trim {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: trim, preferredTimescale: 60_000))
        }
        provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            throw ClipError.unreadable(clip.url, error)
        }
    }

    /// The next frame, or nil after the last.
    ///
    /// iPhone clips have an edit list that starts partway into a frame. AVFoundation shows that
    /// frame first, for what's left of it (5 to 22 ms on the test clips); ffmpeg, and so the demo,
    /// leaves it out. So does this: a first frame shown for under 0.9 of a frame. (Timestamps on a
    /// 1/600 s clock vary by less than that: 16.7 or 18.3 ms at 59.98 fps.)
    public func next() async throws -> Frame? {
        if let frame = pending {
            pending = nil
            return keep(frame)
        }
        guard let frame = try await read() else { return nil }
        if times.isEmpty, let second = try await read() {
            if second.time - frame.time < 0.9 / clip.nominalFrameRate {
                skipped += 1
                return keep(second)
            }
            pending = second
        }
        return keep(frame)
    }

    private func keep(_ frame: Frame) -> Frame {
        times.append(frame.time)
        return Frame(index: times.count - 1, time: frame.time, image: frame.image)
    }

    /// The next frame the track has, up to `trim`; its index is set by ``keep(_:)``.
    private func read() async throws -> Frame? {
        while let ready = try await provider.next() {
            let time = ready.presentationTimeStamp.seconds
            guard case .pixelBuffer(let pixels) = ready.content else { continue }
            if let trim, time >= trim { return nil }
            let image = pixels.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }.oriented(clip.orientation)
            return Frame(index: -1, time: time, image: image)
        }
        return nil
    }

    /// The frames read so far.
    public var count: Int { times.count }

    /// The frame rate the analysis times frames by (`index / fps`, as the demo does): one over the
    /// mean gap between frames, leaving out the gaps where the camera dropped a frame (over 1.5 times
    /// the median). On the test clips that's ffprobe's `r_frame_rate` (24, 30), bar the 60 fps clip:
    /// its timestamps run at 59.98, where ffprobe reads 59.94 from the HEVC stream's timing info.
    /// AVFoundation's nominal rate averages over the dropped frames and the frames before the edit
    /// list's start, so it's lower (23.74 for a 24 fps clip).
    public var fps: Double {
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
        guard !gaps.isEmpty else { return clip.nominalFrameRate }
        let steady = gaps.filter { $0 < 1.5 * gaps[gaps.count / 2] }
        return Double(steady.count) / steady.reduce(0, +)
    }

    /// The presentation time of every frame read so far.
    public var presentationTimes: [Double] { times }
}

extension Frame {
    /// The frame as a JPEG at `url`, at quality 0.95.
    public func writeJPEG(to url: URL, context: CIContext) throws {
        try context.writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
    }

    /// The frame as a PNG at `url`.
    public func writePNG(to url: URL) throws {
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
