import Foundation

// The demo's reports: the summary text (`reps.summary_text`), the two CSVs (`src/export.py`) and
// reps.json (`main.py`), in its columns, keys and rounding.

/// Python's `round(value, digits)`: the double nearest the correctly rounded decimal, ties to even
/// (`String(format:)` rounds the exact binary value as Python's `_Py_dg_dtoa` does).
func pythonRound(_ value: Double, _ digits: Int) -> Double {
    Double(String(format: "%.\(digits)f", value))!
}

/// Python's `format(value, spec)` for the `f` specs the summary uses, via `String(format:)`.
private func format(_ value: Double, _ spec: String) -> String {
    String(format: "%\(spec)", value)
}

extension RepAnalysis {
    /// The human-readable rep report (`summary.txt`), as the demo's `summary_text` writes it.
    public func summaryText(videoSeconds: Double, source: String, settings: Settings) -> String {
        func row(_ label: String, _ value: String) -> String {
            label.padding(toLength: 24, withPad: " ", startingAt: 0) + value
        }
        var lines = ["Push-up summary", String(repeating: "=", count: 64)]
        if !source.isEmpty { lines.append(row("source", source)) }
        lines += [row("clip length", format(videoSeconds, ".2f") + "s"), row("total reps", "\(count)"),
                  row("measured on", "the \(side.rawValue) side")]
        let (full, straight, graded) = tally
        if graded > 0 {
            lines += [row("full range of motion", "\(full) of \(graded)"), row("straight back", "\(straight) of \(graded)")]
        }
        guard let summary = RepSummary(reps, metric: settings.metric) else {
            // The demo points at plots.png, which this port doesn't draw.
            lines.append("\nNo reps detected. Check the frames CSV.")
            return lines.joined(separator: "\n") + "\n"
        }
        lines += [
            "",
            row("concentric", settings.metric.label),
            row("mean", format(summary.meanSeconds, ".2f") + "s"),
            row("fastest", format(summary.fastestSeconds, ".2f") + "s   (rep \(summary.fastestRep))"),
            row("slowest", format(summary.slowestSeconds, ".2f") + "s   (rep \(summary.slowestRep))"),
            row("mean eccentric", format(summary.meanEccentricSeconds, ".2f") + "s"),
            row("mean pause at bottom", format(summary.meanPauseSeconds, ".2f") + "s"),
            row("pace", format(Double(count) / videoSeconds * 60, ".1f") + " reps/min"),
            "",
            "Per rep",
            String(repeating: "-", count: 64),
            "rep   down  pause     up  bottom    top   back  grade",
        ]
        for rep in reps {
            var line = String(format: "%3d %5.2fs %5.2fs %5.2fs  ", rep.number, rep.eccentricSeconds, rep.pauseSeconds,
                              rep.seconds(settings.metric))
            if let g = rep.grade {
                func number(_ value: Double, _ spec: String) -> String {
                    value.isFinite ? format(value, spec) : "    --"
                }
                line += "\(number(g.bottomHeight, "6.2f")) \(number(g.topHeight, "6.2f")) \(number(g.backWorst, "+5.0f"))d  "
                    + "\(g.reason), back \(g.backLabel)"
            }
            lines.append(line)
        }
        lines += [
            "",
            "Held to: bottom <= \(format(settings.romDownHeight, ".2f")), "
                + "top >= \(format(settings.romUpFraction * top, ".2f")) "
                + "(\(format(settings.romUpFraction * 100, ".0f"))% of the \(format(top, ".2f")) plank), "
                + "body line within +/-\(format(settings.backToleranceDegrees, ".0f"))d.",
            "`bottom` and `top` are the shoulder's height above the wrist, in arm lengths",
            "(1 is a vertical straight arm; the wrist is on the floor). `back` is the",
            "hip's worst angle off the shoulder-ankle line: negative is hips low, positive high.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `<clip>_summary.csv`: one row per rep, grades, phase times, heights and angles.
    public func summaryCSV() -> String {
        let header = ["rep", "full_range_of_motion", "straight_back", "note", "descent_starts_s", "bottom_s",
                      "push_up_starts_s", "lockout_s", "down_s", "pause_at_bottom_s", "push_up_s", "bottom_to_lockout_s",
                      "bottom_shoulder_height_arm_lengths", "top_shoulder_height_arm_lengths", "bottom_elbow_deg",
                      "top_elbow_deg", "body_line_worst_deg"]
        let rows = reps.map { r -> [String] in
            let g = r.grade
            let note = g.map { g in [g.complete ? "" : g.reason, g.backOK ? "" : g.backLabel].filter { !$0.isEmpty }
                .joined(separator: ", ") } ?? ""
            return ["\(r.number)", g.map { $0.complete ? "yes" : "no" } ?? "", g.map { $0.backOK ? "yes" : "no" } ?? "", note,
                    cell(r.descentTime), cell(r.bottomTime), cell(r.pushTime), cell(r.lockoutTime),
                    cell(r.eccentricSeconds), cell(r.pauseSeconds), cell(r.concentricSeconds), cell(r.ascentSeconds),
                    cell(g?.bottomHeight), cell(g?.topHeight), cell(g?.bottomElbow, 1), cell(g?.topElbow, 1),
                    cell(g?.backWorst, 1)]
        }
        return csv(header, rows)
    }

    /// `<clip>_frames.csv`: one row per returned frame, every measurement, with the rep and phase
    /// (down, pause, push-up, or blank at the top) it falls in.
    public func framesCSV() -> String {
        let spans = reps.flatMap { r in
            [(r.number, "down", r.descentFrame, r.bottomFrame), (r.number, "pause", r.bottomFrame, r.pushFrame),
             (r.number, "push-up", r.pushFrame, r.lockoutFrame)]
        }
        let header = ["frame", "time_s", "rep", "phase", "shoulder_height_arm_lengths", "shoulder_height_raw_arm_lengths",
                      "elbow_deg", "body_line_deg"]
        let rows = indices.enumerated().map { i, frame -> [String] in
            // Half-open, so a boundary frame belongs to the phase it starts.
            let span = spans.first { $0.2 <= frame && frame < $0.3 }
            return ["\(frame)", cell(times[i], 4), span.map { "\($0.0)" } ?? "", span?.1 ?? "", cell(height[i], 5),
                    cell(raw[i], 5), cell(elbow[i], 2), cell(line[i], 2)]
        }
        return csv(header, rows)
    }

    /// reps.json as the demo's `main.py` writes it: the settings, the summary and every series.
    public func repsJSON(fps: Double, settings: Settings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(RepsFile(analysis: self, fps: fps, settings: settings))
    }

    /// The four reports into `folder`: summary.txt, reps.json and the two CSVs named after the clip.
    public func writeReports(to folder: URL, poses: Poses, settings: Settings) throws {
        let source = poses.video.source
        let stem = (source as NSString).deletingPathExtension
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try summaryText(videoSeconds: Double(poses.video.nFrames) / poses.video.fps, source: source, settings: settings)
            .write(to: folder.appending(component: "summary.txt"), atomically: true, encoding: .utf8)
        try repsJSON(fps: poses.video.fps, settings: settings).write(to: folder.appending(component: "reps.json"))
        if !reps.isEmpty {
            try summaryCSV().write(to: folder.appending(component: "\(stem)_summary.csv"), atomically: true, encoding: .utf8)
        }
        if !indices.isEmpty {
            try framesCSV().write(to: folder.appending(component: "\(stem)_frames.csv"), atomically: true, encoding: .utf8)
        }
    }
}

extension Metric {
    /// What the summary calls the push-up time, and its span.
    public var label: String {
        switch self {
        case .moving: "concentric, moving only (leaving the bottom to lockout)"
        case .ascent: "concentric (deepest point to lockout)"
        }
    }
}

/// The demo's `_num`: a CSV cell rounded to `digits`, blank for nil or NaN, written as Python
/// writes a float (the shortest repr, as Swift's `description` is).
private func cell(_ value: Double?, _ digits: Int = 3) -> String {
    guard let value, !value.isNaN else { return "" }
    return "\(pythonRound(value, digits))"
}

/// Rows as Python's `csv` writes them: the `excel` dialect, `\r\n` line ends, a field quoted only
/// when it holds a comma, a quote or a line break. (Foundation has no CSV writer.)
private func csv(_ header: [String], _ rows: [[String]]) -> String {
    func field(_ text: String) -> String {
        text.contains(where: { ",\"\r\n".contains($0) }) ? "\"" + text.replacing("\"", with: "\"\"") + "\"" : text
    }
    return ([header] + rows).map { $0.map(field).joined(separator: ",") + "\r\n" }.joined()
}

/// reps.json's layout. The keys and their order are the demo's, so it's encoded by hand.
private struct RepsFile: Encodable {
    let analysis: RepAnalysis
    let fps: Double
    let settings: Settings

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: any Encoder) throws {
        var file = encoder.container(keyedBy: Key.self)
        try file.encode(fps, forKey: Key("fps"))
        var signal = file.nestedContainer(keyedBy: Key.self, forKey: Key("signal"))
        try signal.encode(settings.side?.rawValue ?? "auto", forKey: Key("side"))
        try signal.encode(settings.smoothMedianFrames, forKey: Key("smooth_median_frames"))
        try signal.encode(settings.smoothMeanFrames, forKey: Key("smooth_mean_frames"))
        try signal.encode(settings.topPercentile, forKey: Key("top_percentile"))
        try signal.encode(settings.repPeakFraction, forKey: Key("peak_fraction"))
        try signal.encode(settings.repResetFraction, forKey: Key("reset_fraction"))
        try signal.encode(settings.concentricVelocityFraction, forKey: Key("concentric_velocity_fraction"))
        try signal.encode(settings.metric.rawValue, forKey: Key("metric"))
        try signal.encode(settings.romDownHeight, forKey: Key("down_height"))
        try signal.encode(settings.romUpFraction, forKey: Key("up_fraction"))
        try signal.encode(settings.backToleranceDegrees, forKey: Key("back_tolerance_degrees"))

        try file.encode(analysis.count, forKey: Key("reps"))
        if let summary = RepSummary(analysis.reps, metric: settings.metric) {
            let (full, straight, graded) = analysis.tally
            try file.encode(analysis.side.rawValue, forKey: Key("side"))
            try file.encode(full, forKey: Key("full_rom_reps"))
            try file.encode(straight, forKey: Key("straight_back_reps"))
            try file.encode(graded, forKey: Key("graded_reps"))
            try file.encode(pythonRound(analysis.arm, 4), forKey: Key("arm_length_frame_heights"))
            try file.encode(pythonRound(analysis.top, 3), forKey: Key("top_shoulder_height"))
            try file.encode(settings.metric.rawValue, forKey: Key("metric"))
            for (key, value) in [("mean_concentric_seconds", summary.meanSeconds), ("fastest_concentric_seconds", summary.fastestSeconds),
                                 ("slowest_concentric_seconds", summary.slowestSeconds),
                                 ("mean_eccentric_seconds", summary.meanEccentricSeconds),
                                 ("mean_pause_seconds", summary.meanPauseSeconds)] {
                try file.encode(pythonRound(value, 3), forKey: Key(key))
            }
            var details = file.nestedUnkeyedContainer(forKey: Key("reps_detail"))
            for rep in analysis.reps {
                var r = details.nestedContainer(keyedBy: Key.self)
                try r.encode(rep.number, forKey: Key("number"))
                for (key, value) in [("descent_time", rep.descentTime), ("bottom_time", rep.bottomTime), ("push_time", rep.pushTime),
                                     ("lockout_time", rep.lockoutTime), ("eccentric_seconds", rep.eccentricSeconds),
                                     ("pause_seconds", rep.pauseSeconds), ("concentric_seconds", rep.concentricSeconds),
                                     ("ascent_seconds", rep.ascentSeconds), ("depth_arm_lengths", rep.depth)] {
                    try r.encode(pythonRound(value, 3), forKey: Key(key))
                }
                try r.encode(["descent": rep.descentFrame, "bottom": rep.bottomFrame, "push": rep.pushFrame,
                              "lockout": rep.lockoutFrame], forKey: Key("frames"))
                guard let g = rep.grade else {
                    try r.encodeNil(forKey: Key("grade"))
                    continue
                }
                var grade = r.nestedContainer(keyedBy: Key.self, forKey: Key("grade"))
                func number(_ value: Double, _ digits: Int, _ key: String) throws {
                    if value.isFinite { try grade.encode(pythonRound(value, digits), forKey: Key(key)) } else { try grade.encodeNil(forKey: Key(key)) }
                }
                try grade.encode(g.complete, forKey: Key("complete"))
                try grade.encode(g.reason, forKey: Key("reason"))
                try number(g.bottomHeight, 3, "bottom_shoulder_height")
                try number(g.topHeight, 3, "top_shoulder_height")
                try number(g.topRequired, 3, "top_required")
                try number(g.backWorst, 1, "back_worst_degrees")
                try number(g.bottomElbow, 1, "bottom_elbow_degrees")
                try number(g.topElbow, 1, "top_elbow_degrees")
                try grade.encode(g.bottomOK, forKey: Key("bottom_ok"))
                try grade.encode(g.topOK, forKey: Key("top_ok"))
                try grade.encode(g.backOK, forKey: Key("back_ok"))
                try grade.encode(g.backLabel, forKey: Key("back"))
            }
        }

        var series = file.nestedContainer(keyedBy: Key.self, forKey: Key("series"))
        func clean(_ values: [Double], _ digits: Int) -> [Double?] {
            values.map { $0.isFinite ? pythonRound($0, digits) : nil }
        }
        try series.encode(analysis.times.map { pythonRound($0, 4) }, forKey: Key("time"))
        try series.encode(clean(analysis.height, 4), forKey: Key("shoulder_height_arm_lengths"))
        try series.encode(clean(analysis.raw, 4), forKey: Key("shoulder_height_raw"))
        try series.encode(clean(analysis.line, 2), forKey: Key("body_line_degrees"))
        try series.encode(clean(analysis.elbow, 2), forKey: Key("elbow_degrees"))
    }
}
