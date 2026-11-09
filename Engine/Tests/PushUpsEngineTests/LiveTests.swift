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
/// `VideoProcessor` in golden/. Each posed frame is matched by its time. How many Vision poses depends on
/// what else the Mac is doing: 11–14 of the 24 with the other tests running alongside, so it only needs
/// enough to compare; `pushups-cli live` measures the rate.
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
    #expect(posed.count >= 6, "Vision posed \(posed.count) of the first second's 24 frames")
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

/// What dropping frames changes: at 6–15 poses a second (walk-in was posed at 18 a second live, so it drops to 6–9)
/// the straightest frame can fall between the frames kept, a rep's span moves by a frame or two, and a body line close
/// to the back tolerance can land either side of it. Live, Vision poses 18–30 a second, so these stay a stress
/// measurement (#23).
private let knownDropMisses: [String: String] = [
    "clean-right 3 3": "Rep 3 locks out as the clip ends; with one frame in three its top reads 135° against 146°, under 140°",
    "hips-low 3 count": "Rep 3 locks out as the clip ends; with one frame in three the elbow is back to only 140° on the last frame, and a rep still down at the end with the body line −14.5° isn't counted (#42)",
    "back half-reps 2 1": "Rep 1's body line reads 14.5° against 12.5° with every frame, either side of 14° (#56)",
    "back half-reps 3 1": "Rep 1's body line reads 14.5° against 12.5° with every frame, either side of 14° (#56)",
    "back walk-in 2 1": "Rep 1's body line reads 15.6° against −13.6° with every frame",
    "back walk-in 3 1": "Rep 1's body line reads 19.4° against −13.6° with every frame",
    "back walk-in 3 7": "Rep 7's body line reads 25.4° against −15.4° with every frame",
]

/// Frames Vision had no time for, dropped in a fixed pattern from each clip's poses: every second frame (a
/// 60 fps camera posed at 30) and two of every three. The counter sees fewer frames, so its five-frame
/// windows span longer; it must still count and grade every clip as it does with every frame, but for the
/// known misses above.
@Test(arguments: clipNames, [2, 3])
func droppedFramesKeepTheGrades(name: String, every: Int) throws {
    let poses = try Poses(contentsOf: golden(name, "poses-vision.json"))
    let whole = RepCounter(poses: poses, settings: Settings())
    var kept = poses
    kept.frames = poses.frames.enumerated().filter { $0.offset % every == 0 }.map(\.element)
    let thinned = RepCounter(poses: kept, settings: Settings())
    func compared(_ rep: Rep, _ original: Rep) -> String {
        let (a, b) = (rep.grade, original.grade)
        let against = { (x: Double, y: Double) in String(format: "%.1f° against %.1f°", x, y) }
        return "\(rep.number): \(a.reason), \(a.backLabel) (bottom \(against(a.bottomAngle, b.bottomAngle)), "
            + "top \(against(a.topAngle, b.topAngle)), back \(against(a.backWorst, b.backWorst)))"
    }
    print("\(name), 1 frame in \(every): \(thinned.count) reps (\(whole.count) with every frame); "
          + zip(thinned.reps, whole.reps).map(compared).joined(separator: "; "))
    func check(_ key: String, _ body: () -> Void) {
        if let miss = knownDropMisses[key] { withKnownIssue(Comment(rawValue: miss), body) } else { body() }
    }
    check("\(name) \(every) count") { #expect(thinned.count == whole.count) }
    for (rep, original) in zip(thinned.reps, whole.reps) {
        check("\(name) \(every) \(rep.number)") { #expect(rep.grade.reason == original.grade.reason, "rep \(rep.number)") }
        check("back \(name) \(every) \(rep.number)") {
            #expect(rep.grade.backLabel == original.grade.backLabel, "rep \(rep.number)")
        }
    }
}

/// A clip's poses fed to a live set as the camera's posed frames: each rep comes back once, as it's counted,
/// and the set ends with the clip's reps. A setting changed mid-set counts the frames so far again, as if
/// the set had started with it.
@Test(arguments: clipNames)
func liveSetCountsAsTheClip(name: String) throws {
    let poses = try Poses(contentsOf: golden(name, "poses-vision.json"))
    let clip = RepCounter(poses: poses, settings: Settings())
    var set = LiveSet(settings: Settings())
    var counted: [Rep] = []
    var changed = Settings()
    changed.backToleranceDegrees = 20
    for (i, pose) in poses.frames.enumerated() {
        let frame = LiveFrame(pose: pose, presentationTime: CMTime(seconds: pose.time, preferredTimescale: 600),
                              width: poses.width, height: poses.height, arrived: .now, visionSeconds: 0)
        counted += set.add(frame)
        if i == poses.frames.count / 2 {
            var fresh = RepCounter(settings: changed, aspect: poses.aspect)
            for pose in poses.frames[...i] { fresh.add(pose) }
            #expect(set.recounted(with: changed).counter?.reps == fresh.reps)
        }
    }
    counted += set.finish()
    #expect(counted == clip.reps)
    #expect(set.counter?.reps == clip.reps && set.arrivals.count == poses.frames.count)
    #expect(set.finish().isEmpty)
}

/// A live set recorded and read back: every frame in the movie, and every pose at its frame's time, with
/// its joints as they were. Thirty blank frames at a camera's pace, 30 fps, a pose on every other one.
@Test func recordedPosesComeBack() async throws {
    let url = FileManager.default.temporaryDirectory.appending(component: "recorded-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try LiveRecorder(url: url)
    let start = 1000.0   // a camera's times are the host clock's
    var written: [Pose] = []
    for i in 0..<30 {
        let time = CMTime(value: CMTimeValue(30_000 + 1000 * i), timescale: 30_000)   // 1/30 s apart, exactly
        try await Task.sleep(for: .seconds(1.0 / 30))
        recorder.append(try blankFrame(at: start + time.seconds - 1))
        if i.isMultiple(of: 2) {
            let pose = Pose(time: Double(i) / 30, joints: [
                .rightShoulder: Joint(location: CGPoint(x: 0.3 + 0.001 * Double(i), y: 0.4), confidence: 0.9),
                .rightWrist: Joint(location: CGPoint(x: 0.31, y: 0.7), confidence: 0.5),
            ])
            recorder.append(pose, at: CMTime(seconds: start + time.seconds - 1, preferredTimescale: 600_000))
            written.append(pose)
        }
    }
    let counts = try await recorder.finish()
    #expect((counts.frames, counts.poses, counts.skipped) == (30, 15, 0))
    let read = try #require(try await Poses.recorded(in: url))
    #expect((read.width, read.height) == (640, 360))
    #expect(read.frames.count == written.count)
    for (back, pose) in zip(read.frames, written) {
        #expect(abs(back.time - pose.time) < 0.0001)
        #expect(back.joints == pose.joints)
    }
    let video = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    #expect(try await video.load(.timeRange).duration.seconds > 0.9)
}

/// Frames whose times repeat or step back, as the iPhone's do when it takes over (#77), are left out, and so is
/// a pose that would step back with them; the rest of the set is still recorded.
@Test func framesOutOfOrderAreLeftOut() async throws {
    let url = FileManager.default.temporaryDirectory.appending(component: "out-of-order-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try LiveRecorder(url: url)
    let even = (0..<30).map { 1000 + Double($0) / 30 }
    // After the 10th frame, its time again (frame 10 here); after the 20th, the 16th's (frame 21).
    let times = Array(even[0..<10]) + [even[9]] + Array(even[10..<20]) + [even[15]] + Array(even[20...])
    for (i, time) in times.enumerated() {
        try await Task.sleep(for: .seconds(1.0 / 30))
        recorder.append(try blankFrame(at: time))
        // Every other frame posed, and both frames out of order.
        if i.isMultiple(of: 2) || i == 21 {
            recorder.append(Pose(time: time - 1000, joints: [:]), at: CMTime(seconds: time, preferredTimescale: 600))
        }
    }
    let counts = try await recorder.finish()
    // Frame 10's pose is still after the last pose (frame 8's), so it's kept, at frame 9's time; frame 21's
    // would step back from frame 20's, so it's left out.
    #expect((counts.frames, counts.outOfOrder, counts.skipped, counts.poses) == (30, 2, 0, 16))
    let read = try #require(try await Poses.recorded(in: url))
    #expect(read.frames.count == counts.poses)
    #expect(zip(read.frames, read.frames.dropFirst()).allSatisfy { $0.time < $1.time })
    let video = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    #expect(try await video.load(.timeRange).duration.seconds > 0.95)
}

/// A clip filmed on the phone has no recorded poses: it's posed by Vision, as before.
@Test func aClipHasNoRecordedPoses() async throws {
    #expect(try await Poses.recorded(in: testClip("clean-right")) == nil)
}
