import Testing
@testable import PushUpsEngine

/// The whole analysis on each golden poses JSON, with the demo's defaults: the shoulder's speed, the
/// cycles, and every rep's frames, times and depth against the demo's.
@Test(arguments: goldenCases)
func repsMatchPython(name: String, model: String) throws {
    let (poses, dump) = try loadCase(name, model)
    let analysis = analyze(poses)
    let rise = gradient(analysis.height)
    let depth = analysis.height.map { analysis.top - $0 }
    let cycles = repCycles(depth, amplitude: robustDepth(depth), settings: .demo)
    #expect(cycles.map { [$0.start, $0.bottom] } == dump.cycles)
    #expect(analysis.count == dump.reps.count)
    var timeDifference = 0.0, depthDifference = 0.0
    for (rep, python) in zip(analysis.reps, dump.reps) {
        #expect([rep.descentFrame, rep.bottomFrame, rep.pushFrame, rep.lockoutFrame]
                == ["descent", "bottom", "push", "lockout"].map { python.frames[$0]! }, "rep \(rep.number)")
        let times = [rep.descentTime, rep.bottomTime, rep.pushTime, rep.lockoutTime]
        timeDifference = zip(times, ["descent", "bottom", "push", "lockout"].map { python.times[$0]! })
            .reduce(timeDifference) { max($0, abs($1.0 - $1.1)) }
        depthDifference = max(depthDifference, abs(rep.depth - python.depth!))
    }
    let differences = [maxDifference(rise, dump.rise), maxDifference(analysis.times, dump.times), timeDifference, depthDifference]
    print("\(name): \(analysis.count) reps = \(dump.reps.count), cycles \(cycles.map { [$0.start, $0.bottom] }); speed \(sci(differences[0])), frame times \(sci(differences[1])), phase times \(sci(differences[2])) s, depth \(sci(differences[3]))")
    #expect(differences.allSatisfy { $0 <= tolerance }, "\(differences)")
}

@Test func walkStopsAtTheWindow() {
    let speed: [Double] = [0, 1, 5, 10, 6, 3, 0.5]
    #expect(walk(speed, from: 3, within: 0...6, step: 1, fraction: 0.1) == 6)
    #expect(walk(speed, from: 3, within: 0...6, step: -1, fraction: 0.1) == 1)   // 1 is at the floor: `<=`
    #expect(walk(speed, from: 3, within: 2...5, step: 1, fraction: 0.1) == 5)
    #expect(argmax([1, 3, 3, 2][...]) == 1)
}
