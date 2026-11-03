import Testing
@testable import PushUpsEngine

/// The engine ports the commit README.md and tools/golden.py name.
@Test func referenceCommit() {
    #expect(PushUpsEngine.referenceCommit.hasPrefix("d28ca19"))
    #expect(PushUpsEngine.referenceCommit.count == 40)
}
