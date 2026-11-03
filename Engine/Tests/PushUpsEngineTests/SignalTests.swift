import Testing
@testable import PushUpsEngine

/// The gap-filled, median-filtered and smoothed height, the plank level and the typical depth
/// against the demo's, from the same raw height, with the demo's defaults (5 and 5 frames, 90th
/// percentile).
@Test(arguments: goldenCases)
func signalMatchesPython(name: String, model: String) throws {
    let (_, dump) = try loadCase(name, model)
    let raw = dump.raw.map { $0 ?? .nan }
    let filled = fillGaps(raw)
    let medians = medianFilter(filled, 5)
    let height = boxFilter(medians, 5)
    let top = percentile(height, 90)
    let depth = height.map { top - $0 }
    let amplitude = robustDepth(depth)
    let differences = [maxDifference(filled, dump.filled), maxDifference(medians, dump.median),
                       maxDifference(height, dump.height), abs(top - dump.top!), abs(amplitude - dump.amplitude!)]
    print("\(name): filled \(sci(differences[0])), median \(sci(differences[1])), smoothed \(sci(differences[2])), plank \(sci(differences[3])), typical depth \(sci(differences[4]))")
    #expect(differences.allSatisfy { $0 <= tolerance }, "\(differences)")
}

@Test func fillGapsEnds() {
    #expect(fillGaps([.nan, 1, .nan, 3, .nan]) == [1, 1, 2, 3, 3])
    #expect(fillGaps([.nan, .nan]) == [0, 0])
    #expect(fillGaps([1, .infinity]) == [1, 1])
}

@Test func filtersBumpEvenSizes() {
    let x: [Double] = [1, 5, 2, 8, 3, 9]
    #expect(medianFilter(x, 4) == medianFilter(x, 5))
    #expect(boxFilter(x, 4) == boxFilter(x, 5))
    #expect(medianFilter([.nan, .nan, .nan, 4], 3).map(\.isNaN) == [true, true, false, false])
}

/// `np.percentile`'s values on small inputs, worked by hand from its definition.
@Test func percentileInterpolates() {
    #expect(percentile([1, 2, 3, 4], 90) == 4 - 1 * (1 - 0.7000000000000002))   // index 2.7, from the upper value
    #expect(percentile([1, 2, 3, 4], 10) == 1 + 1 * 0.30000000000000004)        // index 0.3, from the lower
    #expect(percentile([5], 95) == 5)
}
