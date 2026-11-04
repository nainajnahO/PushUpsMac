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
