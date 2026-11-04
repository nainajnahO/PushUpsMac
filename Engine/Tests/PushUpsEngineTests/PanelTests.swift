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

/// The panel's smoothing is in seconds: the same step, sampled at 24 and at 60 fps, is smoothed alike, and
/// about the step, so the curve isn't moved in time.
@Test func displaySmoothingIsInSeconds() {
    func smoothedStep(fps: Double) -> (times: [Double], values: [Double]) {
        let times = (0..<Int(2 * fps)).map { Double($0) / fps }
        return (times, displaySmoothed(times.map { $0 < 1 ? 0 : 1 }, times: times))
    }
    let (slow, fast) = (smoothedStep(fps: 24), smoothedStep(fps: 60))
    #expect(abs(slow.values[23] + slow.values[24] - 1) < 1e-9 && abs(fast.values[59] + fast.values[60] - 1) < 1e-9)
    for time in [0.875, 0.95, 1.05, 1.125] {
        let a = slow.values[slow.times.lastIndex { $0 <= time }!], b = fast.values[fast.times.lastIndex { $0 <= time }!]
        #expect(abs(a - b) < 0.1, "at \(time) s: \(a) at 24 fps, \(b) at 60 fps")
    }
}

/// A frame without a value stays without one, and the frames next to it and at the ends are smoothed over those
/// that have one: a constant stays constant.
@Test func displaySmoothingKeepsGaps() {
    let times = (0..<60).map { Double($0) / 30 }
    let series = times.indices.map { $0 == 20 || $0 == 21 ? Double.nan : 0.75 }
    let smoothed = displaySmoothed(series, times: times)
    #expect(smoothed[20].isNaN && smoothed[21].isNaN)
    #expect(smoothed.indices.filter { !(20...21).contains($0) }.allSatisfy { abs(smoothed[$0] - 0.75) < 1e-12 })
}
