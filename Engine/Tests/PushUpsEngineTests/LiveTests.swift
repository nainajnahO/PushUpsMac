import AVFoundation
import CoreVideo
import Testing
@testable import PushUpsEngine

/// A blank camera frame, 640 × 360, shown at `time` seconds.
private func blankFrame(at time: Double) throws -> CMReadySampleBuffer<CVReadOnlyPixelBuffer> {
    let format = CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let pixels = try CVMutablePixelBuffer(CVPixelBufferCreationAttributes(pixelFormatType: format,
                                                                          size: CVImageSize(width: 640, height: 360)))
    return CMReadySampleBuffer(pixelBuffer: CVReadOnlyPixelBuffer(pixels),
                               presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600))
}

/// Frames that come while Vision is on an earlier one are dropped and counted, and none after `finish()`
/// is taken. The frames end once Vision is done. A pose is timed from the first frame received.
@Test func livePoserDropsWhileBusy() async throws {
    let poser = LivePoser()
    // Ten frames back to back, far faster than Vision: it takes the first and is busy for the rest.
    for i in 0..<10 { poser.receive(try blankFrame(at: 5 + Double(i) / 30)) }
    poser.finish()
    poser.receive(try blankFrame(at: 6))
    var posed: [LiveFrame] = []
    for await frame in poser.frames { posed.append(frame) }
    let counts = poser.counts
    #expect((counts.received, counts.dropped, counts.failed) == (10, 9, 0))
    #expect(posed.count == 1)
    let frame = try #require(posed.first)
    #expect(frame.pose.time == 0 && frame.pose.joints.isEmpty)
    #expect((frame.width, frame.height) == (640, 360))
}

/// The live path reads the same athlete as a clip does: clean-right's first second, decoded to the 8-bit
/// frames a camera delivers and handed over at the clip's own pace, against Vision's poses from
/// `VideoProcessor` in golden/. Each posed frame is matched by its time.
@Test func livePosesMatchTheClip() async throws {
    let url = try testClip("clean-right")
    let golden = try Poses(contentsOf: golden("clean-right", "poses-vision.json"))
    let poser = LivePoser()
    let delivery = Task.detached {
        defer { poser.finish() }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        let clock = ContinuousClock(), start = clock.now
        var first: Double?
        while let sample = try await provider.next() {
            guard let frame = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else { continue }
            let time = frame.presentationTimeStamp.seconds
            first = first ?? time
            try await clock.sleep(until: start + .seconds(time - first!))
            poser.receive(frame)
        }
        return first ?? 0
    }
    var posed: [LiveFrame] = []
    for await frame in poser.frames { posed.append(frame) }
    let first = try await delivery.value
    #expect(posed.count >= 12, "Vision posed \(posed.count) of the first second's 24 frames")
    var worst = 0.0
    for frame in posed {
        let time = frame.pose.time + first
        let match = try #require(golden.frames.first { abs($0.time - time) < 0.001 }, "no golden frame at \(time) s")
        for name in Side.right.joints {
            let live = try #require(frame.pose.joints[name]), clip = try #require(match.joints[name])
            worst = max(worst, abs(live.location.x - clip.location.x), abs(live.location.y - clip.location.y))
        }
    }
    print("live against clip, clean-right's first second: \(posed.count) frames posed, the near side's joints within \(String(format: "%.4f", worst)) of the frame")
    #expect(worst < 0.01)
}
