import Foundation
import PushUpsEngine

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "poses":
    // pushups-cli poses <clip> -o <poses.json> [--trim SECONDS] [--height PX]: Vision on every frame,
    // as golden/<clip>/poses-vision.json holds them.
    arguments.removeFirst()
    let trim = option("--trim").map { number($0) as Double }
    let height = option("--height").map { number($0) as Int } ?? 1080
    guard let output = option("-o"), let path = arguments.first, arguments.count == 1 else { usage() }
    try await writePoses(of: URL(filePath: path), to: URL(filePath: output), height: height, trim: trim)
case "analyze":
    // pushups-cli analyze <clip | poses.json> [--trim S] [--down ARMS] [--up FRACTION]
    // [--back-tolerance DEG] [--metric moving|ascent] [--side auto|left|right]: prints the reps.
    arguments.removeFirst()
    let settings = settingOptions()
    let trim = option("--trim").map { number($0) as Double }
    guard let path = arguments.first, arguments.count == 1 else { usage() }
    try await printAnalysis(of: URL(filePath: path), settings: settings, trim: trim)
default:
    usage()
}

func usage() -> Never {
    print("""
        Usage: pushups-cli poses <clip> -o <poses.json> [--trim SECONDS] [--height PX]
               pushups-cli analyze <clip | poses.json> [--trim SECONDS] [--down ARMS] [--up FRACTION]
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

@MainActor func option(_ name: String) -> String? {
    option(name, count: 1)?.first
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

/// The reps in a clip (posed by Vision first) or in a poses JSON, one line each, and the tallies.
func printAnalysis(of url: URL, settings: Settings, trim: Double?) async throws {
    let poses = url.pathExtension.lowercased() == "json"
        ? try Poses(contentsOf: url)
        : try await Poses.detect(in: Clip(url: url), trim: trim)
    let analysis = analyze(poses, settings: settings)
    let (full, straight, graded) = analysis.tally
    print("\(poses.video.source): \(analysis.count) reps on the \(analysis.side.rawValue) side, "
          + "\(full)/\(graded) full range, \(straight)/\(graded) straight back")
    for rep in analysis.reps {
        let row = rep.row(metric: settings.metric)
        var line = "rep \(row.id)  at \(fixed(row.startSeconds, 2)) s  down \(fixed(row.downSeconds, 2)) s  "
            + "pause \(fixed(row.pauseSeconds, 2)) s  push-up \(fixed(row.pushUpSeconds, 2)) s"
        if let grade = rep.grade {
            line += "  \(grade.reason) (bottom \(fixed(grade.bottomHeight, 2)), top \(fixed(grade.topHeight, 2))"
                + " of \(fixed(grade.topRequired, 2))), \(grade.backLabel) (\(fixed(grade.backWorst, 1))°)"
        }
        print(line)
    }
}
