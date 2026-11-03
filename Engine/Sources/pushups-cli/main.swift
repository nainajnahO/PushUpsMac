import Foundation
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
default:
    print("pushups-cli — port of the vision-demos push-ups demo at \(PushUpsEngine.referenceCommit.prefix(7))")
    usage()
}

func usage() -> Never {
    print("""
        Usage: pushups-cli frames <clip> [--trim SECONDS] [--height PX] [--png INDEX FILE]
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
