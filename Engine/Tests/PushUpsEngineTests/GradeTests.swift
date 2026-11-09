import Testing
@testable import PushUpsEngine

@Test func gradeLabels() {
    // A rep whose elbow bends to 60° and opens back to 155°, its hips 20° low on one frame.
    let elbow = [160, 120, 60, 120, 155, 160.0]
    let line = [0, -5, -20, -5, 0, 0.0]
    let grade = Grade(elbow: elbow, line: line, span: 0...4, push: 2...4, settings: Settings())
    #expect(grade.bottomOK && grade.topOK && !grade.backOK)
    #expect(grade.reason == "full" && grade.backLabel == "hips low" && grade.backWorst == -20)
}

/// What's said for a rep: the number alone, or with cues, what fell short in the sidebar's words.
@Test func spokenCount() {
    // The elbow to 60° and back to 155°: full, but the hips 20° low on one frame.
    let bent = Grade(elbow: [160, 120, 60, 120, 155, 160], line: [0, -5, -20, -5, 0, 0], span: 0...4, push: 2...4,
                     settings: Settings())
    // The elbow only to 120° and back to 130°: not to the floor and not back up, straight.
    let short = Grade(elbow: [160, 135, 120, 125, 130, 130], line: [0, 1, 2, 1, 0, 0], span: 0...4, push: 2...4,
                      settings: Settings())
    // Full, but the body line unseen.
    let unseen = Grade(elbow: [160, 120, 60, 120, 155, 160], line: [.nan, .nan, .nan, .nan, .nan, .nan], span: 0...4,
                       push: 2...4, settings: Settings())
    func rep(_ number: Int, _ grade: Grade) -> Rep {
        Rep(number: number, descentFrame: 0, bottomFrame: 2, pushFrame: 2, lockoutFrame: 4, descentTime: 0, bottomTime: 0.2,
            pushTime: 0.2, lockoutTime: 0.4, grade: grade)
    }
    #expect(rep(3, bent).spoken(cues: false) == "3")
    #expect(rep(3, bent).spoken(cues: true) == "3, hips low")
    #expect(rep(12, short).spoken(cues: true) == "12, not to the floor, not back up")
    #expect(rep(4, unseen).spoken(cues: true) == "4")
}
