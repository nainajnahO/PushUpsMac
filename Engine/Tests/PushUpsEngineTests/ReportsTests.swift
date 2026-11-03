import Foundation
import Testing
@testable import PushUpsEngine

/// summary.txt and both CSVs character for character, and reps.json value for value, against the
/// demo's own reports on the same keypoints with its defaults.
@Test(arguments: goldenCases)
func reportsMatchPython(name: String, model: String) throws {
    let (poses, dump) = try loadCase(name, model)
    let analysis = analyze(poses)
    let text = analysis.summaryText(videoSeconds: Double(dump.input.n_frames) / dump.input.fps, source: dump.input.source,
                                    settings: .demo)
    #expect(text == dump.summary_txt)
    #expect(analysis.summaryCSV() == dump.summary_csv)
    let frames = analysis.framesCSV()
    #expect(frames == dump.frames_csv)
    let swift = try JSONSerialization.jsonObject(with: analysis.repsJSON(fps: poses.video.fps, settings: .demo)) as! NSDictionary
    let python = try JSONSerialization.jsonObject(with: Data(dump.reps_json.utf8)) as! NSDictionary
    #expect(swift == python)
    let cells = { (csv: String) in csv.split(separator: "\r\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) } }
    let differing = zip(cells(frames), cells(dump.frames_csv)).reduce(0) { n, rows in n + zip(rows.0, rows.1).count { $0 != $1 } }
    print("\(name): summary.txt \(text == dump.summary_txt ? "identical" : "differs"), summary CSV \(analysis.summaryCSV() == dump.summary_csv ? "identical" : "differs"), frames CSV \(differing) of \(cells(frames).joined().count) cells differ, reps.json \(swift == python ? "equal" : "differs")")
}

@Test func roundsAsPython() {
    #expect(pythonRound(0.125, 2) == 0.12)      // a tie on the exact binary value: to even
    #expect(pythonRound(2.675, 2) == 2.67)      // 2.675 is 2.67499999… in binary
    #expect(pythonRound(-0.0001, 3) == 0 && pythonRound(1.0005, 3) == 1.0)
}

/// The app's rep list shows what `reps.json`'s `reps_detail` holds, rep for rep, with either metric.
@Test(arguments: goldenCases)
func repRowsMatchRepsJSON(name: String, model: String) throws {
    let (poses, dump) = try loadCase(name, model)
    let json = try JSONSerialization.jsonObject(with: Data(dump.reps_json.utf8)) as! [String: Any]
    let details = json["reps_detail"] as! [[String: Any]]
    for metric in Metric.allCases {
        var settings = Settings.demo
        settings.metric = metric
        let rows = analyze(poses, settings: settings).reps.map { $0.row(metric: metric) }
        try #require(rows.count == details.count)
        for (row, detail) in zip(rows, details) {
            let grade = detail["grade"] as? [String: Any]
            #expect(row.id == detail["number"] as? Int)
            #expect(pythonRound(row.startSeconds, 3) == detail["descent_time"] as? Double)
            #expect(pythonRound(row.downSeconds, 3) == detail["eccentric_seconds"] as? Double)
            #expect(pythonRound(row.pauseSeconds, 3) == detail["pause_seconds"] as? Double)
            #expect(pythonRound(row.pushUpSeconds, 3) == detail[metric == .moving ? "concentric_seconds" : "ascent_seconds"] as? Double)
            #expect(row.range == grade?["reason"] as? String)
            #expect(row.back == grade?["back"] as? String)
            #expect(row.complete == (grade?["complete"] as? Bool ?? true))
            #expect(row.straight == (grade?["back_ok"] as? Bool ?? true))
        }
    }
}

/// A setting changes the grades without posing again: hips-low's first rep, 0.75 at the bottom, is
/// full at a down height of 0.80, and its sag (−19° at worst on Vision) passes at 20°.
@Test func changingASettingRegrades() throws {
    let (poses, _) = try loadCase("hips-low", "vision")
    var settings = Settings.app
    #expect(analyze(poses, settings: settings).reps.map(\.complete) == [false, true, true])
    #expect(analyze(poses, settings: settings).reps.map(\.straight) == [false, false, false])
    settings.romDownHeight = 0.80
    settings.backToleranceDegrees = 20
    #expect(analyze(poses, settings: settings).reps.map(\.complete) == [true, true, true])
    #expect(analyze(poses, settings: settings).reps.map(\.straight) == [true, true, true])
}
