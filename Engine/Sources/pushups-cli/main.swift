import AVFoundation
import Foundation
import PushUpsEngine

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "poses":
    // pushups-cli poses <clip> -o <poses.json> [--trim SECONDS]: Vision on every frame, as
    // golden/<clip>/poses-vision.json holds them.
    arguments.removeFirst()
    let trim = option("--trim").map { number($0) as Double }
    guard let output = option("-o"), let path = arguments.first, arguments.count == 1 else { usage() }
    try await writePoses(of: URL(filePath: path), to: URL(filePath: output), trim: trim)
case "analyze":
    // pushups-cli analyze <clip | poses.json> [--trim S] [--down ARMS] [--up FRACTION]
    // [--back-tolerance DEG] [--metric moving|ascent] [--side auto|left|right]: prints the reps.
    arguments.removeFirst()
    let settings = settingOptions()
    let trim = option("--trim").map { number($0) as Double }
    guard let path = arguments.first, arguments.count == 1 else { usage() }
    try await printAnalysis(of: URL(filePath: path), settings: settings, trim: trim)
case "live":
    // pushups-cli live <clip> [--size WIDTHxHEIGHT] [--trim SECONDS] [--compare poses.json] [settings]: the
    // clip played into the live path at its own pace, as a camera would deliver it; prints what Vision kept
    // up with and what was counted live, against the clip's own poses with --compare.
    arguments.removeFirst()
    let size = option("--size").map(frameSize)
    let trim = option("--trim").map { number($0) as Double }
    let clip = option("--compare").map { URL(filePath: $0) }
    let speak = flag("--speak")
    let record = option("--record").map { URL(filePath: $0) }
    let loops = option("--loop").map { number($0) as Int } ?? 1
    let settings = settingOptions()
    guard let path = arguments.first, arguments.count == 1 else { usage() }
    try await printLive(of: URL(filePath: path), size: size, trim: trim, settings: settings, clip: clip, speak: speak,
                        record: record, loops: loops)
case "speed":
    // pushups-cli speed <poses.json> [--minutes M]: counting, the live counter and the panel on a set M minutes
    // long (10 by default), made of the clip's poses over and over.
    arguments.removeFirst()
    let minutes = option("--minutes").map { number($0) as Double } ?? 10
    guard let path = arguments.first, arguments.count == 1 else { usage() }
    try printSpeed(of: URL(filePath: path), minutes: minutes)
default:
    usage()
}

func usage() -> Never {
    print("""
        Usage: pushups-cli poses <clip> -o <poses.json> [--trim SECONDS]
               pushups-cli analyze <clip | poses.json> [--trim SECONDS] [--down ARMS] [--up FRACTION]
                                   [--back-tolerance DEG] [--metric moving|ascent] [--side auto|left|right]
               pushups-cli live <clip> [--size WIDTHxHEIGHT] [--trim SECONDS] [--compare <poses.json>] [--speak]
                                [--record <movie.mov>] [--loop TIMES]
                                [--down ARMS] [--up FRACTION] [--back-tolerance DEG] [--side auto|left|right]
               pushups-cli speed <poses.json> [--minutes MINUTES]
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

@MainActor func option(_ name: String) -> String? {
    option(name, count: 1)?.first
}

/// Whether `name` is among `arguments`, taking it out.
@MainActor func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
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

/// The analysis settings from the command line, the app's defaults otherwise.
@MainActor func settingOptions() -> Settings {
    var settings = Settings()
    option("--down").map { settings.romDownHeight = number($0) }
    option("--up").map { settings.romUpFraction = number($0) }
    option("--back-tolerance").map { settings.backToleranceDegrees = number($0) }
    option("--metric").map { settings.metric = Metric(rawValue: $0) ?? badValue() }
    option("--side").map { settings.side = $0 == "auto" ? nil : Side(rawValue: $0) ?? badValue() }
    return settings
}

/// Vision's poses on every frame of the clip, as a poses JSON, with how long Vision took.
func writePoses(of url: URL, to output: URL, trim: Double?) async throws {
    let start = ContinuousClock.now
    let poses = try await Poses.detect(in: url, trim: trim)
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    try poses.write(to: output)
    let frames = poses.frames
    let span = (frames.last?.time ?? 0) - (frames.first?.time ?? 0)
    print("""
        \(output.lastPathComponent): \(frames.count) frames shown at \(poses.width) × \(poses.height), \
        \(fixed(frames.first?.time ?? 0, 3)) to \(fixed(frames.last?.time ?? 0, 3)) s \
        (\(fixed(Double(frames.count - 1) / span, 2)) fps on average); a person on \(frames.count { !$0.joints.isEmpty }); \
        \(fixed(seconds * 1000 / Double(frames.count), 1)) ms per frame, \(fixed(seconds, 1)) s in all
        """)
}

/// The reps in a clip (posed by Vision first) or in a poses JSON, one line each, and the tallies.
func printAnalysis(of url: URL, settings: Settings, trim: Double?) async throws {
    let poses = url.pathExtension.lowercased() == "json"
        ? try Poses(contentsOf: url)
        : try await Poses.detect(in: url, trim: trim)
    let counter = RepCounter(poses: poses, settings: settings)
    let (full, straight, graded) = counter.tally
    guard let plank = counter.plank, let side = counter.side else {
        print("\(poses.source): no plank found")
        return
    }
    print("\(poses.source): \(counter.count) reps on the \(side.rawValue) side, \(full)/\(graded) full range, "
          + "\(straight)/\(graded) straight back; plank at \(fixed(counter.times[plank.frame], 2)) s (frame \(plank.frame)), "
          + "arm \(fixed(plank.arm, 3)) frame heights, level \(fixed(plank.level, 2))")
    for rep in counter.reps {
        let (row, grade) = (rep.row(metric: settings.metric), rep.grade)
        print("rep \(row.id)  at \(fixed(row.startSeconds, 2)) s  down \(fixed(row.downSeconds, 2)) s  "
              + "pause \(fixed(row.pauseSeconds, 2)) s  push-up \(fixed(row.pushUpSeconds, 2)) s  "
              + "\(grade.reason) (bottom \(fixed(grade.bottomHeight, 2)), top \(fixed(grade.topHeight, 2))"
              + " of \(fixed(grade.topRequired, 2))), \(grade.backLabel) (\(fixed(grade.backWorst, 1))°)")
    }
}
