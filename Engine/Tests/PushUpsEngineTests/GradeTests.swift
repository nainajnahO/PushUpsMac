import Testing
@testable import PushUpsEngine

@Test func gradeLabels() {
    // A rep that goes down to 0.3 and back to 0.95 of a 1.0 plank, its hips 20° low on one frame.
    let height = [1, 0.6, 0.3, 0.6, 0.95, 1.0]
    let line = [0, -5, -20, -5, 0, 0.0]
    let grade = Grade(height: height, line: line, plank: 1, span: 0...4, push: 2...4, settings: Settings())
    #expect(grade.bottomOK && grade.topOK && !grade.backOK)
    #expect(grade.reason == "full" && grade.backLabel == "hips low" && grade.backWorst == -20)
}

/// What's said for a rep: the number alone, or with cues, what fell short in the sidebar's words.
@Test func spokenCount() {
    // Down to 0.3 and back to 0.95 of a 1.0 plank: full, but the hips 20° low on one frame.
    let bent = Grade(height: [1, 0.6, 0.3, 0.6, 0.95, 1.0], line: [0, -5, -20, -5, 0, 0], plank: 1, span: 0...4, push: 2...4,
                     settings: Settings())
    // Only down to 0.7 and back to 0.8: not to the floor and not back up, straight.
    let short = Grade(height: [1, 0.8, 0.7, 0.75, 0.8, 0.8], line: [0, 1, 2, 1, 0, 0], plank: 1, span: 0...4, push: 2...4,
                      settings: Settings())
    // Straight, but the body line unseen.
    let unseen = Grade(height: [1, 0.6, 0.3, 0.6, 0.95, 1.0], line: [.nan, .nan, .nan, .nan, .nan, .nan], plank: 1,
                       span: 0...4, push: 2...4, settings: Settings())
    func rep(_ number: Int, _ grade: Grade) -> Rep {
        Rep(number: number, descentFrame: 0, bottomFrame: 2, pushFrame: 2, lockoutFrame: 4, descentTime: 0, bottomTime: 0.2,
            pushTime: 0.2, lockoutTime: 0.4, depth: 0.7, grade: grade)
    }
    #expect(rep(3, bent).spoken(cues: false) == "3")
    #expect(rep(3, bent).spoken(cues: true) == "3, hips low")
    #expect(rep(12, short).spoken(cues: true) == "12, not to the floor, not back up")
    #expect(rep(4, unseen).spoken(cues: true) == "4")
}
