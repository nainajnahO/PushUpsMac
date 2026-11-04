import Testing
@testable import PushUpsEngine

@Test func fillGapsEnds() {
    #expect(fillGaps([.nan, 1, .nan, 3, .nan]) == [1, 1, 2, 3, 3])
    #expect(fillGaps([.nan, .nan]) == [0, 0])
    #expect(fillGaps([1, .infinity]) == [1, 1])
}

@Test func medianSkipsWhatIsMissing() {
    #expect(median([3, .nan, 1, 2]) == 2)
    #expect(median([4, 1, 3, 2]) == 2.5)
    #expect(median([Double.nan]).isNaN)
}
