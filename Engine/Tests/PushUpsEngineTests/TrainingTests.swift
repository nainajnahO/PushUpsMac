import Foundation
import Testing
@testable import PushUpsEngine

/// A rep at `start` seconds into its set: half a second down, a tenth held, `push` up.
private func rep(at start: Double, push: Double = 0.8, full: Bool = true, straight: Bool = true) -> SavedRep {
    SavedRep(descentTime: start, bottomTime: start + 0.5, pushTime: start + 0.6, lockoutTime: start + 0.6 + push,
             bottomOK: full, topOK: true, backOK: straight)
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2   // Monday
    return calendar
}()

/// 2026-11-`day` at `hour`:00 UTC. The 2nd is a Monday.
private func date(_ day: Int, _ hour: Int) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

/// A saved rep keeps what the history reads of a counted one: its push-up time by either metric and its grade.
@Test(arguments: clipNames)
func savedRepsKeepTimesAndGrades(name: String) throws {
    let counter = RepCounter(poses: try Poses(contentsOf: golden(name, "poses-vision.json")), settings: Settings())
    for rep in counter.reps {
        let saved = SavedRep(rep)
        for metric in Metric.allCases { #expect(saved.seconds(metric) == rep.seconds(metric)) }
        #expect(saved.complete == rep.complete && saved.backOK == rep.straight)
    }
}

/// Sets are gathered by the calendar's day, with each day's shares and mean push-up time over its reps, and the
/// same over the seven days up to it.
@Test func setsGatherByDay() {
    let sets = [
        PastSet(start: date(5, 23), reps: [rep(at: 0, push: 1), rep(at: 2, push: 0.6, full: false)]),
        PastSet(start: date(6, 7), reps: [rep(at: 0, straight: false), rep(at: 2), rep(at: 4), rep(at: 6, full: false)]),
        // The same day, in UTC, as the set before.
        PastSet(start: date(6, 21), reps: [rep(at: 0)]),
    ]
    let training = Training(sets, metric: .moving, now: date(6, 22), calendar: utc)
    #expect(training.days.map(\.day) == [date(5, 0), date(6, 0)])
    let (first, second) = (training.days[0], training.days[1])
    #expect((first.sets, first.reps, second.sets, second.reps) == (1, 2, 2, 5))
    #expect(first.full == 0.5 && first.straight == 1 && abs(first.seconds - 0.8) < 1e-9)
    #expect(second.full == 0.8 && second.straight == 0.8 && abs(second.seconds - 0.8) < 1e-9)
    // The 5th's week is the 5th alone; the 6th's takes in the 5th's two reps.
    #expect(first.weekFull == first.full && first.weekStraight == first.straight)
    #expect(abs(second.weekFull - 5.0 / 7) < 1e-9 && abs(second.weekStraight - 6.0 / 7) < 1e-9)
    #expect(abs(second.weekSeconds - 0.8) < 1e-9)
    #expect((training.reps, training.biggestSet) == (7, 4))
}

/// A rep's place in its set is gathered over the sets that got that far, as far as enough sets got: with two
/// sets, both; with forty, four.
@Test func repsGatherByPlace() {
    let sets = [
        PastSet(start: date(6, 7), reps: [rep(at: 0), rep(at: 2, full: false), rep(at: 4)]),
        PastSet(start: date(6, 8), reps: [rep(at: 0, push: 0.6), rep(at: 2, straight: false), rep(at: 4), rep(at: 6)]),
    ]
    let training = Training(sets, metric: .moving, now: date(6, 9), calendar: utc)
    #expect(training.fewestSets == 2 && training.biggestSet == 4)
    let places = training.places
    #expect(places.map(\.number) == [1, 2, 3])
    #expect(places.map(\.sets) == [2, 2, 2])
    #expect(places.map(\.full) == [1, 0.5, 1])
    #expect(places.map(\.straight) == [1, 0.5, 1])
    #expect(abs(places[0].seconds - 0.7) < 1e-9)
    let many = (0..<40).map { PastSet(start: date(6, 7).addingTimeInterval(Double($0) * 600), reps: Array(repeating: rep(at: 0), count: 1 + $0)) }
    let manyPlaces = Training(many, metric: .moving, now: date(6, 9), calendar: utc).places
    // Rep 37 is the last that four of the forty sets got to.
    #expect(manyPlaces.count == 37 && manyPlaces.last?.sets == 4)
}

/// The week's reps are the calendar week's, the last seven days' shares are today's and the six before, the
/// charts span at least four weeks, and the days in a row end today, or yesterday before today's first set; a
/// day without one breaks them.
@Test func weekAndDaysInARow() {
    let sets = [date(1, 9), date(3, 9), date(4, 9), date(5, 9)].map { PastSet(start: $0, reps: [rep(at: 0), rep(at: 2, full: $0 == date(1, 9))]) }
    let thursday = Training(sets, metric: .moving, now: date(5, 20), calendar: utc)
    // Sunday the 1st is the week before.
    #expect((thursday.weekReps, thursday.lastWeekReps) == (6, 2))
    #expect(thursday.recentFull == 5.0 / 8 && thursday.recentStraight == 1)
    #expect(thursday.span == utc.date(from: DateComponents(year: 2026, month: 10, day: 9))!...date(6, 0))
    #expect(thursday.streak == 3)
    // Friday, before its first set: still three.
    #expect(Training(sets, metric: .moving, now: date(6, 8), calendar: utc).streak == 3)
    // Saturday: Friday had none. Two weeks on, nothing in the last seven days.
    #expect(Training(sets, metric: .moving, now: date(7, 8), calendar: utc).streak == 0)
    #expect(Training(sets, metric: .moving, now: date(19, 8), calendar: utc).recentFull == nil)
    let none = Training([], metric: .moving, now: date(7, 8), calendar: utc)
    #expect(none.days.isEmpty && none.places.isEmpty && (none.reps, none.streak, none.weekReps) == (0, 0, 0))
}

/// Merged sets start at the first one's start, oldest first, each set's reps at their times from there.
@Test func mergedSetsKeepTheirTimes() throws {
    let later = PastSet(start: date(6, 7).addingTimeInterval(30), reps: [rep(at: 1)])
    let earlier = PastSet(start: date(6, 7), reps: [rep(at: 0), rep(at: 2)])
    let merged = try #require(PastSet.merged([later, earlier]))
    #expect(merged.start == earlier.start)
    #expect(merged.reps.map(\.descentTime) == [0, 2, 31])
    #expect(abs(merged.reps[2].seconds(.moving) - later.reps[0].seconds(.moving)) < 1e-9)
    #expect(PastSet.merged([]) == nil)
}
