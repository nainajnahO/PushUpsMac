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

/// The misses Vision's poses and the app's defaults make against your notes, and where each is
/// worked on. A known issue that stops happening fails the test, so the table stays true.
private let knownMisses: [String: String] = [
    "count fast-reps": "Lying down after the set counts as a 5th rep (#42)",
    "down hips-low 1": "Rep 1 reads 0.75 at the bottom, over the app's 0.70 (ViTPose: 0.71); docs/porting.md",
    "back half-reps 1": "Rep 1's body line reads +15.5° on both models, past 14°; docs/porting.md",
]

/// Vision's poses and the Swift analysis with the app's defaults, held against your counts: the
/// number of reps, and each rep's "not back up", "not to the floor" and back.
@Test(arguments: clipNames)
func countsAgainstTruth(name: String) throws {
    let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: golden(name, "truth.json")))
    let analysis = analyze(try Poses(contentsOf: golden(name, "poses-vision.json")), settings: .app)
    func check(_ key: String, _ body: () -> Void) {
        if let miss = knownMisses[key] { withKnownIssue(Comment(rawValue: miss), body) } else { body() }
    }
    check("count \(name)") { #expect(analysis.count == truth.reps) }
    let pairs = zip(analysis.reps, truth.per_rep).map { ($0.grade!, $1) }
    for (grade, rep) in pairs {
        #expect(grade.topOK == !rep.reason.contains("not back up"), "rep \(rep.rep)")
        check("back \(name) \(rep.rep)") { #expect(grade.backLabel == rep.back, "rep \(rep.rep)") }
    }
    for (grade, rep) in pairs {
        check("down \(name) \(rep.rep)") { #expect(grade.bottomOK == !rep.reason.contains("not to the floor"), "rep \(rep.rep)") }
    }
    print("\(name): \(analysis.count) reps (yours \(truth.reps)); " + pairs.map { "\($1.rep): \($0.reason), \($0.backLabel)" }.joined(separator: "; "))
}
