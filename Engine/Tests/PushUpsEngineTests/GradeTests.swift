import Foundation
import Testing
@testable import PushUpsEngine

/// Every rep's grade fields against the demo's, with its defaults, on the same keypoints: the
/// readings within 1e-9, the verdicts and labels identical; the tallies too.
@Test(arguments: goldenCases)
func gradesMatchPython(name: String, model: String) throws {
    let (poses, dump) = try loadCase(name, model)
    let analysis = analyze(poses)
    #expect(analysis.count == dump.reps.count)
    var worst = 0.0
    var verdicts: [String] = []
    for (rep, python) in zip(analysis.reps, dump.reps) {
        let grade = try #require(rep.grade), p = try #require(python.grade)
        let pairs: [(Double, Double?)] = [(grade.bottomHeight, p.bottom_height), (grade.topHeight, p.top_height),
                                          (grade.topRequired, p.top_required), (grade.backWorst, p.back_worst),
                                          (grade.bottomElbow, p.bottom_elbow), (grade.topElbow, p.top_elbow)]
        worst = max(worst, maxDifference(pairs.map(\.0), pairs.map(\.1)))
        #expect([grade.bottomOK, grade.topOK, grade.backOK, grade.complete] == [p.bottom_ok, p.top_ok, p.back_ok, p.complete],
                "rep \(rep.number)")
        #expect(grade.reason == p.reason && grade.backLabel == p.back_label, "rep \(rep.number)")
        verdicts.append("\(grade.reason) / \(grade.backLabel)")
    }
    let tally = analysis.tally
    #expect([tally.full, tally.straight, tally.graded] == dump.tally)
    print("\(name): readings \(sci(worst)); \(tally.full)/\(tally.graded) full, \(tally.straight)/\(tally.graded) straight; \(verdicts.joined(separator: "; "))")
    #expect(worst <= tolerance)

    // The summary numbers, against reps.json's (rounded to 3 decimals there).
    let json = try JSONSerialization.jsonObject(with: Data(dump.reps_json.utf8)) as! [String: Any]
    if let summary = RepSummary(analysis.reps, metric: .moving) {
        let pairs = [(summary.meanSeconds, "mean_concentric_seconds"), (summary.fastestSeconds, "fastest_concentric_seconds"),
                     (summary.slowestSeconds, "slowest_concentric_seconds"), (summary.meanEccentricSeconds, "mean_eccentric_seconds"),
                     (summary.meanPauseSeconds, "mean_pause_seconds")]
        for (value, key) in pairs {
            #expect(abs(value - (json[key] as! Double)) <= 0.0005, "\(key)")
        }
    }
}

@Test func gradeLabels() {
    var settings = Settings.demo
    settings.romSampleFrames = 1
    settings.backSampleFrames = 1
    // A rep that goes down to 0.3 and back to 0.95 of a 1.0 plank, its hips 20° low on one frame.
    let height = [1, 0.6, 0.3, 0.6, 0.95, 1.0]
    let line = [0, -5, -20, -5, 0, 0.0]
    let grade = Grade(height: height, line: line, elbow: height.map { $0 * 100 }, plank: 1, span: 0...4, push: 2...4,
                      settings: settings)
    #expect(grade.bottomOK && grade.topOK && !grade.backOK)
    #expect(grade.reason == "full" && grade.backLabel == "hips low" && grade.backWorst == -20)
}
