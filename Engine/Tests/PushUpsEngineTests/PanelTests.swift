import Testing
@testable import PushUpsEngine

/// The panel's tallies count only the reps locked out by the playhead: none at the start, then each
/// rep from its lockout frame, and at the end the whole clip's summary.
@Test(arguments: clipNames)
func panelTalliesFollowThePlayhead(name: String) throws {
    let analysis = RepCounter(poses: try Poses(contentsOf: golden(name, "poses-vision.json")), settings: Settings())
    let start = analysis.panelState(atFrame: 0, metric: .moving)
    #expect(start.done.isEmpty && start.averageSeconds == nil && start.graded == 0)
    for rep in analysis.reps {
        #expect(analysis.panelState(atFrame: rep.lockoutFrame - 1, metric: .moving).done.count == rep.number - 1)
        #expect(analysis.panelState(atFrame: rep.lockoutFrame, metric: .moving).done.count == rep.number)
    }
    let end = analysis.panelState(atFrame: analysis.times.count - 1, metric: .moving)
    let tally = analysis.tally
    #expect((end.done.count, end.full, end.straight, end.graded) == (analysis.count, tally.full, tally.straight, tally.graded))
    #expect(end.averageSeconds == RepSummary(analysis.reps, metric: .moving)?.meanSeconds)
}

/// The panel's display smoothing keeps a level series level, bridges a gap up to 0.1 s (2 frames at
/// 24 fps) and leaves a longer one, and the ends, unseen.
@Test func displaySmoothingBridgesShortGapsOnly() {
    let nan = Double.nan
    let series = [nan, 2, 2, nan, nan, 2, 2, nan, nan, nan, 2, 2, nan]
    let smoothed = displaySmooth(series, fps: 24, seconds: panelSmoothSeconds)
    #expect(smoothed.map(\.isNaN) == [true, false, false, false, false, false, false, true, true, true, false, false, true])
    #expect(smoothed.filter { !$0.isNaN }.allSatisfy { abs($0 - 2) < 1e-12 })
}
