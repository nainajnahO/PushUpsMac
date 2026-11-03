import CoreImage
import Foundation
import ImageIO
import PushUpsEngine

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "frames":
    // pushups-cli frames <clip> [--trim SECONDS] [--height PX] [--png INDEX FILE]: reads every frame
    // and prints what it read.
    arguments.removeFirst()
    let trim = option("--trim").map { number($0) as Double }
    let height = option("--height").map { number($0) as Int }
    let png = option("--png", count: 2).map { (number($0[0]) as Int, URL(filePath: $0[1])) }
    guard let path = arguments.first, arguments.count == 1 else { usage() }
    try await printFrames(of: URL(filePath: path), height: height, trim: trim, png: png)
case "poses":
    // pushups-cli poses <clip> -o <poses.json> [--trim SECONDS] [--height PX]: Vision on every frame,
    // written as the demo's gateway replies.
    arguments.removeFirst()
    let trim = option("--trim").map { number($0) as Double }
    let height = option("--height").map { number($0) as Int } ?? 1080
    guard let output = option("-o"), let path = arguments.first, arguments.count == 1 else { usage() }
    try await writePoses(of: URL(filePath: path), to: URL(filePath: output), height: height, trim: trim)
case "draw":
    // pushups-cli draw <clip> <poses.json>... --frames N,N,... -o <folder> [--trim SECONDS]: each
    // listed frame with the joints from each poses JSON drawn on it (the first in green, then
    // magenta, cyan), as PNGs.
    arguments.removeFirst()
    let trim = option("--trim").map { number($0) as Double }
    guard let list = option("--frames"), let output = option("-o"), arguments.count >= 2 else { usage() }
    let indices = Set(list.split(separator: ",").map { number(String($0)) as Int })
    try await drawPoses(of: URL(filePath: arguments[0]), poses: arguments.dropFirst().map { URL(filePath: $0) },
                        frames: indices, to: URL(filePath: output), trim: trim)
case "analyze":
    // pushups-cli analyze <clip | poses.json> -o <folder> [--trim S] [--down ARMS] [--up FRACTION]
    // [--back-tolerance DEG] [--metric moving|ascent] [--side auto|left|right]: the demo's reports.
    arguments.removeFirst()
    var settings = Settings.demo
    let trim = option("--trim").map { number($0) as Double }
    option("--down").map { settings.romDownHeight = number($0) }
    option("--up").map { settings.romUpFraction = number($0) }
    option("--back-tolerance").map { settings.backToleranceDegrees = number($0) }
    option("--metric").map { settings.metric = Metric(rawValue: $0) ?? badValue() }
    option("--side").map { settings.side = $0 == "auto" ? nil : Side(rawValue: $0) ?? badValue() }
    guard let output = option("-o"), let path = arguments.first, arguments.count == 1 else { usage() }
    try await writeAnalysis(of: URL(filePath: path), to: URL(filePath: output), settings: settings, trim: trim)
default:
    print("pushups-cli — port of the vision-demos push-ups demo at \(PushUpsEngine.referenceCommit.prefix(7))")
    usage()
}

func usage() -> Never {
    print("""
        Usage: pushups-cli frames <clip> [--trim SECONDS] [--height PX] [--png INDEX FILE]
               pushups-cli poses <clip> -o <poses.json> [--trim SECONDS] [--height PX]
               pushups-cli draw <clip> <poses.json>... --frames N,N,... -o <folder> [--trim SECONDS]
               pushups-cli analyze <clip | poses.json> -o <folder> [--trim SECONDS] [--down ARMS] [--up FRACTION]
                                   [--back-tolerance DEG] [--metric moving|ascent] [--side auto|left|right]
        """)
    exit(1)
}

/// Takes `name` and the `count` values after it out of `arguments`.
@MainActor func option(_ name: String, count: Int = 1) -> [String]? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + count < arguments.count else { usage() }
    defer { arguments.removeSubrange(i...(i + count)) }
    return Array(arguments[(i + 1)...(i + count)])
}

/// `value` with `digits` decimals, in any locale.
func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

func number<T: LosslessStringConvertible>(_ text: String) -> T {
    guard let value = T(text) else { usage() }
    return value
}

func badValue<T>() -> T {
    usage()
}

@MainActor func option(_ name: String) -> String? {
    option(name, count: 1)?.first
}

/// Reads the clip's frames as the poses will, and prints the clip's geometry, frame rate and count.
func printFrames(of url: URL, height: Int?, trim: Double?, png: (Int, URL)?) async throws {
    let clip = try await Clip(url: url)
    let frames = try await clip.frames(height: height, trim: trim)
    let start = ContinuousClock.now
    while let frame = try await frames.next() {
        if let png, frame.index == png.0 {
            try frame.writePNG(to: png.1)
        }
    }
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    let times = frames.presentationTimes
    // How far `index / fps`, the demo's time, strays from each frame's presentation time: a frame
    // the camera dropped makes the frames after it a frame early.
    let drift = times.enumerated().map { abs(Double($0.offset) / frames.fps - ($0.element - times[0])) }.max() ?? 0
    print("""
        clip         \(url.lastPathComponent)
        stored       \(clip.storedWidth) × \(clip.storedHeight), rotation \(clip.rotation)°
        shown        \(clip.width) × \(clip.height)
        read at      \(frames.width) × \(frames.height)\(clip.isHDR ? ", HDR tone-mapped to SDR" : "")
        fps          \(fixed(frames.fps, 3)) (AVFoundation's nominal \(fixed(clip.nominalFrameRate, 3)))
        frames       \(frames.count)\(frames.skipped > 0 ? " (and \(frames.skipped) the edit list cuts into, left out)" : "")
        first, last  \(times.first ?? 0) s, \(times.last ?? 0) s\(trim.map { " (trimmed to \($0) s)" } ?? "")
        index / fps  within \(fixed((drift * 1000), 1)) ms of each frame's time
        read in      \(fixed(seconds, 2)) s
        """)
}

/// Vision's poses on every frame of the clip, as a poses JSON.
func writePoses(of url: URL, to output: URL, height: Int, trim: Double?) async throws {
    let clip = try await Clip(url: url)
    let start = ContinuousClock.now
    let poses = try await Poses.detect(in: clip, height: height, trim: trim)
    try poses.write(to: output)
    let seen = Set(poses.content.items.map(\.frameID)).count
    print("""
        \(output.lastPathComponent): \(poses.video.nFrames) frames at \(poses.video.width) × \(poses.video.height), \
        \(fixed(poses.video.fps, 3)) fps; a person on \(seen); \
        Vision \(fixed(poses.video.msPerFrame ?? 0, 1)) ms per frame, \
        \(fixed((ContinuousClock.now - start) / .seconds(1), 1)) s in all
        """)
}

/// The listed frames with each poses JSON's joints drawn on them: the COCO skeleton without the
/// face, as the demo draws it, in a colour per JSON.
func drawPoses(of url: URL, poses urls: [URL], frames indices: Set<Int>, to folder: URL, trim: Double?) async throws {
    let clip = try await Clip(url: url)
    let poses = try urls.map { try Poses(contentsOf: $0).byFrame }
    let frames = try await clip.frames(height: 1080, trim: trim)
    let colors: [CGColor] = [CGColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1), CGColor(red: 0.95, green: 0.2, blue: 0.85, alpha: 1),
                             CGColor(red: 0.1, green: 0.8, blue: 0.95, alpha: 1)]
    // The demo's SKELETON, less the edges to the face.
    let edges = [(15, 13), (13, 11), (16, 14), (14, 12), (11, 12), (5, 11), (6, 12), (5, 6), (5, 7), (7, 9), (6, 8), (8, 10)]
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let context = CIContext()
    while let frame = try await frames.next() {
        guard indices.contains(frame.index) else { continue }
        let (width, height) = (frames.width, frames.height)
        guard let image = context.createCGImage(frame.image, from: frame.image.extent),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { continue }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Keypoints are y down; Core Graphics is y up.
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: CGFloat(width), y: -CGFloat(height))
        for (n, byFrame) in poses.enumerated() where byFrame.indices.contains(frame.index) {
            for person in byFrame[frame.index] {
                let point = { (i: Int) -> CGPoint? in
                    person.keypoints[i] == [0, 0] ? nil : CGPoint(x: person.keypoints[i][0], y: person.keypoints[i][1])
                }
                bitmap.setStrokeColor(colors[n % colors.count])
                bitmap.setFillColor(colors[n % colors.count])
                bitmap.setLineWidth(3 / CGFloat(height))
                for (a, b) in edges {
                    if let p = point(a), let q = point(b) {
                        bitmap.strokeLineSegments(between: [p, q])
                    }
                }
                for i in 5..<17 {
                    if let p = point(i) {
                        let r = 5 / CGFloat(height)
                        bitmap.fillEllipse(in: CGRect(x: p.x - r * CGFloat(height) / CGFloat(width), y: p.y - r,
                                                      width: 2 * r * CGFloat(height) / CGFloat(width), height: 2 * r))
                    }
                }
            }
        }
        let output = folder.appending(component: "\(clip.url.deletingPathExtension().lastPathComponent)-\(frame.index).png")
        guard let drawn = bitmap.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)
        else { continue }
        CGImageDestinationAddImage(destination, drawn, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// The demo's reports for a clip (posed by Vision first, the poses kept as poses.json beside them)
/// or for a poses JSON, with the summary printed.
func writeAnalysis(of url: URL, to folder: URL, settings: Settings, trim: Double?) async throws {
    let poses: Poses
    if url.pathExtension.lowercased() == "json" {
        poses = try Poses(contentsOf: url)
    } else {
        poses = try await Poses.detect(in: Clip(url: url), trim: trim)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try poses.write(to: folder.appending(component: "poses.json"))
    }
    let analysis = analyze(poses, settings: settings)
    try analysis.writeReports(to: folder, poses: poses, settings: settings)
    print(analysis.summaryText(videoSeconds: Double(poses.video.nFrames) / poses.video.fps, source: poses.video.source,
                               settings: settings), terminator: "")
}
