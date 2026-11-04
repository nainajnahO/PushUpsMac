import Testing
@testable import PushUpsEngine

@Test func medianSkipsWhatIsMissing() {
    #expect(median([3, .nan, 1, 2]) == 2)
    #expect(median([4, 1, 3, 2]) == 2.5)
    #expect(median([Double.nan]).isNaN)
}
