import Testing
@testable import PushUpsEngine

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
