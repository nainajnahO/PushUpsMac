import Testing
@testable import PushUpsEngine

@Test func walkStopsAtTheWindow() {
    let speed: [Double] = [0, 1, 5, 10, 6, 3, 0.5]
    #expect(walk(speed, from: 3, within: 0...6, step: 1, fraction: 0.1) == 6)
    #expect(walk(speed, from: 3, within: 0...6, step: -1, fraction: 0.1) == 1)   // 1 is at the floor: `<=`
    #expect(walk(speed, from: 3, within: 2...5, step: 1, fraction: 0.1) == 5)
    #expect(argmax([1, 3, 3, 2][...]) == 1)
}
