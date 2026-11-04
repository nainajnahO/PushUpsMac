import Foundation

/// One rep's form: how far down, how far back up, how straight. Every reading is an extreme of a 5-frame
/// median, so one bad pose can't decide a rep.
public struct Grade: Sendable, Equatable {
    /// The shoulder above the wrist at the deepest point, arm lengths.
    public var bottomHeight: Double
    /// ...at lockout.
    public var topHeight: Double
    /// What lockout had to reach: a share of the plank.
    public var topRequired: Double
    /// The body-line reading furthest from straight, signed degrees.
    public var backWorst: Double
    public var bottomOK: Bool
    public var topOK: Bool
    public var backOK: Bool

    /// Full range of motion: chest down to the floor and all the way back up.
    public var complete: Bool { bottomOK && topOK }

    public var reason: String {
        let short = [("not to the floor", bottomOK), ("not back up", topOK)].filter { !$0.1 }.map(\.0)
        return short.isEmpty ? "full" : short.joined(separator: ", ")
    }

    public var backLabel: String {
        guard backWorst.isFinite else { return "unseen" }
        if backOK { return "straight" }
        return backWorst < 0 ? "hips low" : "hips high"
    }

    /// Grades the rep spanning `span` (descent to lockout) with its push `push`, positions in the per-frame
    /// readings: `height` the shoulder above the wrist and `line` the body line, each through a 5-frame
    /// median. `plank` is the plank's level.
    init(height: [Double], line: [Double], plank: Double, span: ClosedRange<Int>, push: ClosedRange<Int>,
         settings: Settings) {
        bottomHeight = extreme(height[span], by: <)
        topHeight = extreme(height[push], by: >)
        topRequired = settings.romUpFraction * plank
        // The first reading furthest from straight.
        let readings = line[span].filter(\.isFinite)
        backWorst = readings.reduce(Double.nan) { worst, x in worst.isNaN || abs(x) > abs(worst) ? x : worst }
        // An end Vision couldn't see counts as short.
        bottomOK = bottomHeight.isFinite && bottomHeight <= settings.romDownHeight
        topOK = topHeight.isFinite && topHeight >= topRequired
        backOK = backWorst.isFinite && abs(backWorst) <= settings.backToleranceDegrees
    }
}

/// The smallest (`<`) or largest (`>`) finite value, NaN if there's none.
private func extreme(_ values: ArraySlice<Double>, by order: (Double, Double) -> Bool) -> Double {
    values.filter(\.isFinite).reduce(Double.nan) { best, x in best.isNaN || order(x, best) ? x : best }
}

/// The summary numbers: the push-up time per rep by `metric`, and the means.
public struct RepSummary: Sendable, Equatable {
    public var meanSeconds: Double
    public var fastestSeconds: Double
    public var slowestSeconds: Double
    /// 1-based rep numbers of the first fastest and the first slowest.
    public var fastestRep: Int
    public var slowestRep: Int
    public var meanEccentricSeconds: Double
    public var meanPauseSeconds: Double

    /// Nil without reps.
    public init?(_ reps: [Rep], metric: Metric) {
        guard !reps.isEmpty else { return nil }
        let values = reps.map { $0.seconds(metric) }
        meanSeconds = mean(values)
        fastestSeconds = values.min()!
        slowestSeconds = values.max()!
        fastestRep = values.firstIndex(of: fastestSeconds)! + 1
        slowestRep = values.firstIndex(of: slowestSeconds)! + 1
        meanEccentricSeconds = mean(reps.map(\.eccentricSeconds))
        meanPauseSeconds = mean(reps.map(\.pauseSeconds))
    }
}

/// The mean of a few values.
func mean(_ values: [Double]) -> Double {
    values.reduce(0, +) / Double(values.count)
}

/// One rep as the app lists it: where it starts (a click jumps there), its times, and its grade.
public struct RepRow: Identifiable, Sendable, Equatable {
    /// The rep's number.
    public var id: Int
    public var startSeconds: Double
    public var downSeconds: Double
    public var pauseSeconds: Double
    /// By the metric: leaving the bottom to lockout (moving), or the deepest point to lockout (ascent).
    public var pushUpSeconds: Double
    /// "full", "not to the floor", "not back up".
    public var range: String
    /// "straight", "hips low", "hips high", "unseen".
    public var back: String
    public var complete: Bool
    public var straight: Bool
}

extension Rep {
    /// What's said as the rep is counted: its number, and with `cues`, what fell short, in the sidebar's words
    /// ("3, not to the floor, hips low"). No cue where Vision didn't see the back.
    public func spoken(cues: Bool) -> String {
        var words = ["\(number)"]
        if cues {
            if !complete { words.append(grade.reason) }
            if !straight, grade.backWorst.isFinite { words.append(grade.backLabel) }
        }
        return words.joined(separator: ", ")
    }

    public func row(metric: Metric) -> RepRow {
        RepRow(id: number, startSeconds: descentTime, downSeconds: eccentricSeconds, pauseSeconds: pauseSeconds,
               pushUpSeconds: seconds(metric), range: grade.reason, back: grade.backLabel,
               complete: complete, straight: straight)
    }
}
