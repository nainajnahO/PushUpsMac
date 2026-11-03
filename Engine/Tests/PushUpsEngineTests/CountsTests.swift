import Foundation
import Testing
@testable import PushUpsEngine

/// Your own count and notes for a test clip, in `golden/<clip>/truth.json`.
struct Truth: Decodable {
    struct Rep: Decodable {
        let rep: Int
        let reason: String
        let back: String
    }
    let reps: Int
    let per_rep: [Rep]
}

/// The misses Vision's poses and the demo's settings make against your notes, and where each is
/// worked on. A known issue that stops happening fails the test, so the table stays true.
private let knownMisses: [String: String] = [
    "count fast-reps": "Lying down after the set counts as a 5th rep (#42)",
    "down": "The demo's 0.40 down height, set on ViTPose, grades your full reps short (#14)",
    "back half-reps 1": "Rep 1's body line reads +15.5° on both models, against 15° allowed (#14)",
    "back hips-low 3": "Rep 3's body line reads −14.9° on Vision, inside 15° (ViTPose: −18.6°) (#14)",
]

/// Vision's poses and the Swift analysis with the demo's defaults, held against your counts: the
/// number of reps, and each rep's "not back up", "not to the floor" and back.
@Test(arguments: clipNames)
func countsAgainstTruth(name: String) throws {
    let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: golden(name, "truth.json")))
    let analysis = analyze(try Poses(contentsOf: golden(name, "poses-vision.json")))
    func check(_ key: String, _ body: () -> Void) {
        if let miss = knownMisses[key] { withKnownIssue(Comment(rawValue: miss), body) } else { body() }
    }
    check("count \(name)") { #expect(analysis.count == truth.reps) }
    let pairs = zip(analysis.reps, truth.per_rep).map { ($0.grade!, $1) }
    for (grade, rep) in pairs {
        #expect(grade.topOK == !rep.reason.contains("not back up"), "rep \(rep.rep)")
        check("back \(name) \(rep.rep)") { #expect(grade.backLabel == rep.back, "rep \(rep.rep)") }
    }
    check("down") {
        for (grade, rep) in pairs { #expect(grade.bottomOK == !rep.reason.contains("not to the floor"), "rep \(rep.rep)") }
    }
    print("\(name): \(analysis.count) reps (yours \(truth.reps)); " + pairs.map { "\($1.rep): \($0.reason), \($0.backLabel)" }.joined(separator: "; "))
}
