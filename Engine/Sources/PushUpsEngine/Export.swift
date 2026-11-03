import AVFoundation
import CoreImage
import SwiftUI

// The demo's export (`render.py` with `EXPORT_SQUARE`): every frame of the clip scaled to 1080 wide,
// with the overlay drawn on it, and the panel under it filling the rest of a square. H.264 in an MP4,
// without the audio, as the demo writes it. The reports go beside it.

extension RepAnalysis {
    /// Writes the annotated video, `<clip>_push_ups.mp4`, and the reports (``writeReports(to:poses:settings:)``)
    /// into `folder`, from the frames `poses` were found on (`trim`, as when posing). `progress` hears
    /// each frame written. Returns the video's URL.
    @MainActor
    public func export(_ clip: Clip, poses: Poses, settings: Settings, style: OverlayStyle, to folder: URL,
                       width: Int = 1080, trim: Double? = nil, progress: (Int) -> Void = { _ in }) async throws -> URL {
        try writeReports(to: folder, poses: poses, settings: settings)
        let url = folder.appending(component: "\((poses.video.source as NSString).deletingPathExtension)_push_ups.mp4")
        try? FileManager.default.removeItem(at: url)

        // ffmpeg's `scale='min(1080,iw)':-2`: down to `width` wide, an even height.
        let shown = clip.size(height: nil)
        let height = shown.width > width ? Int((Double(shown.height * width) / Double(shown.width) / 2).rounded()) * 2 : shown.height
        let frames = try await clip.frames(height: height, trim: trim)
        let (w, h) = (frames.width, frames.height)
        // Square when the clip is landscape; else the demo's `PANEL_HEIGHT`, 0.62 of the clip's.
        let panelHeight = w > h ? w - h : Int((Double(h) * 0.62 / 2).rounded()) * 2

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h + panelHeight,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                                                         size: CVImageSize(width: w, height: h + panelHeight),
                                                         compatibility: [.cgImage, .cgBitmapContext])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)   // adds the input
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
        var start: Double?
        var last = 0.0
        while let frame = try await frames.next() {
            guard let picture = context.createCGImage(frame.image, from: frame.image.extent) else { throw ClipError.unreadable(clip.url, nil) }
            let view = VStack(spacing: 0) {
                ZStack {
                    Image(decorative: picture, scale: 1)
                    if let overlay = overlay(atSourceFrame: frame.index, tolerance: settings.backToleranceDegrees) {
                        OverlayView(frame: overlay, style: style)
                    }
                }
                .frame(width: CGFloat(w), height: CGFloat(h))
                PanelView(analysis: self, settings: settings, fps: poses.video.fps, frames: poses.video.nFrames,
                          playhead: frame.index)
                    .frame(width: CGFloat(w), height: CGFloat(panelHeight))
            }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { throw ClipError.unreadable(clip.url, nil) }
            let buffer: CVMutablePixelBuffer
            if let pool = receiver.pixelBufferPool { buffer = try pool.makeMutablePixelBuffer() } else { buffer = try CVMutablePixelBuffer(attributes) }
            buffer.withUnsafeBuffer { pixels in
                context.render(CIImage(cgImage: image), to: pixels, bounds: CGRect(x: 0, y: 0, width: w, height: h + panelHeight),
                               colorSpace: rec709)
            }
            // The clip's own frame times, from its first frame shown.
            let time = frame.time - (start ?? frame.time)
            start = start ?? frame.time
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(seconds: time, preferredTimescale: 90_000))
            last = time
            progress(frame.index)
        }
        receiver.finish()
        // The last frame lasts a frame, so the movie is as long as the clip.
        writer.endSession(atSourceTime: CMTime(seconds: last + 1 / frames.fps, preferredTimescale: 90_000))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ClipError.unreadable(url, nil) }
        return url
    }
}
