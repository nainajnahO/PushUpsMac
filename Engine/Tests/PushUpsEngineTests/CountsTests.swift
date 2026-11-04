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

/// The misses Vision's poses and the default settings make against your notes, and where each is
/// worked on. A known issue that stops happening fails the test, so the table stays true.
private let knownMisses: [String: String] = [
    "down hips-low 1": "Rep 1 reads 0.66 at the bottom, over 0.60; the half rep reads 0.63 (#57)",
    "back half-reps 1": "Rep 1's body line reads +14.5°, past 14° (#56)",
]

/// Vision's poses through the counter with the default settings, held against your counts: the number
/// of reps, and each rep's "not back up", "not to the floor" and back.
@Test(arguments: clipNames)
func countsAgainstTruth(name: String) throws {
    let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: golden(name, "truth.json")))
    let analysis = RepCounter(poses: try Poses(contentsOf: golden(name, "poses-vision.json")), settings: Settings())
    func check(_ key: String, _ body: () -> Void) {
        if let miss = knownMisses[key] { withKnownIssue(Comment(rawValue: miss), body) } else { body() }
    }
    check("count \(name)") { #expect(analysis.count == truth.reps) }
    let pairs = zip(analysis.reps, truth.per_rep).map { ($0.grade, $1) }
    for (grade, rep) in pairs {
        #expect(grade.topOK == !rep.reason.contains("not back up"), "rep \(rep.rep)")
        check("back \(name) \(rep.rep)") { #expect(grade.backLabel == rep.back, "rep \(rep.rep)") }
    }
    for (grade, rep) in pairs {
        check("down \(name) \(rep.rep)") { #expect(grade.bottomOK == !rep.reason.contains("not to the floor"), "rep \(rep.rep)") }
    }
    print("\(name): \(analysis.count) reps (yours \(truth.reps)); " + pairs.map { "\($1.rep): \($0.reason), \($0.backLabel)" }.joined(separator: "; "))
}

/// A setting changes the grades without posing again: hips-low's first rep, 0.66 at the bottom, is
/// full at a down height of 0.70, and its sag (−19° at worst) passes at 20°.
@Test func changingASettingRegrades() throws {
    let poses = try Poses(contentsOf: golden("hips-low", "poses-vision.json"))
    var settings = Settings()
    #expect(RepCounter(poses: poses, settings: settings).reps.map(\.complete) == [false, true, true])
    #expect(RepCounter(poses: poses, settings: settings).reps.map(\.straight) == [false, false, false])
    settings.romDownHeight = 0.70
    settings.backToleranceDegrees = 20
    #expect(RepCounter(poses: poses, settings: settings).reps.map(\.complete) == [true, true, true])
    #expect(RepCounter(poses: poses, settings: settings).reps.map(\.straight) == [true, true, true])
}

/// Fed one frame at a time, as live: after every frame the reps so far are the first reps of the whole
/// clip's, so a rep, once counted, never changes. Counting the clip whole is the same counting.
@Test(arguments: clipNames)
func repsNeverChangeOnceCounted(name: String) throws {
    let poses = try Poses(contentsOf: golden(name, "poses-vision.json"))
    let whole = RepCounter(poses: poses, settings: Settings())
    var live = RepCounter(settings: Settings(), aspect: poses.aspect)
    var counted: [Int] = []
    for pose in poses.frames {
        live.add(pose)
        #expect(Array(whole.reps.prefix(live.reps.count)) == live.reps)
        counted.append(live.reps.count)
    }
    live.finish()
    #expect(live.reps == whole.reps)
    #expect(live.height == whole.height && live.plank == whole.plank)
    // Each rep is counted five frames after it locks out (a sixth of a second at 30 fps), or at the end of
    // the set if it locks out less than five frames before, or doesn't come back up.
    for rep in live.reps {
        guard let frame = counted.firstIndex(of: rep.number) else {
            print("\(name) rep \(rep.number): counted at the end of the set")
            continue
        }
        #expect(frame == rep.lockoutFrame + 5, "rep \(rep.number)")
        let delay = poses.frames[frame].time - poses.frames[rep.lockoutFrame].time
        print("\(name) rep \(rep.number): counted \(String(format: "%.0f", delay * 1000)) ms after its lockout")
    }
}
