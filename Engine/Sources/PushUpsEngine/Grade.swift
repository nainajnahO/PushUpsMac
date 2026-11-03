import Foundation

/// One rep's form, as the demo's `form.grade` reads it: how far down, how far back up, how
/// straight. Every reading is an extreme of a median-filtered series, so one bad pose can't decide
/// a rep.
public struct Grade: Sendable, Equatable {
    /// The shoulder above the wrist at the deepest point, arm lengths.
    public var bottomHeight: Double
    /// ...at lockout.
    public var topHeight: Double
    /// What lockout had to reach: a share of the clip's plank.
    public var topRequired: Double
    /// The body-line reading furthest from straight, signed degrees.
    public var backWorst: Double
    /// Reported, not graded: the near elbow at its most bent and at its straightest.
    public var bottomElbow: Double
    public var topElbow: Double
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

    /// Grades the rep spanning `span` (descent to lockout) with its push `push`, array positions in
    /// the per-frame series. `height` is the raw shoulder height, `plank` its level at the top of the
    /// clip; `elbow` is only reported.
    init(height: [Double], line: [Double], elbow: [Double], plank: Double, span: ClosedRange<Int>,
         push: ClosedRange<Int>, settings: Settings) {
        let heightSmoothed = medianFilter(height, settings.romSampleFrames)
        let lineSmoothed = medianFilter(line, settings.backSampleFrames)
        let elbowSmoothed = medianFilter(elbow, settings.romSampleFrames)
        // Lockout is the highest the shoulder gets on the way up, a few frames past the measured end,
        // so a lockout reached as the speed dies away still counts.
        let lockout = push.lowerBound...min(height.count - 1, push.upperBound + settings.romSampleFrames)

        bottomHeight = extreme(heightSmoothed[span], by: <)
        topHeight = extreme(heightSmoothed[lockout], by: >)
        topRequired = settings.romUpFraction * plank
        bottomElbow = extreme(elbowSmoothed[span], by: <)
        topElbow = extreme(elbowSmoothed[lockout], by: >)
        // The first reading furthest from straight, as `np.argmax(np.abs(seg))` picks it.
        let readings = lineSmoothed[span].filter(\.isFinite)
        backWorst = readings.reduce(Double.nan) { worst, x in worst.isNaN || abs(x) > abs(worst) ? x : worst }
        // An end the model couldn't see counts as short.
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
    /// 1-based rep numbers of the first fastest and the first slowest, as `np.argmin` and `np.argmax`.
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

/// `np.mean` of a few values: their sum in order, over the count.
func mean(_ values: [Double]) -> Double {
    values.reduce(0, +) / Double(values.count)
}

/// One rep as the app lists it: where it starts (a click jumps there), its times, and its grade,
/// the values `reps.json`'s `reps_detail` holds for it.
public struct RepRow: Identifiable, Sendable, Equatable {
    /// The rep's number.
    public var id: Int
    public var startSeconds: Double
    public var downSeconds: Double
    public var pauseSeconds: Double
    /// By the metric: leaving the bottom to lockout (moving), or the deepest point to lockout (ascent).
    public var pushUpSeconds: Double
    /// "full", "not to the floor", "not back up"; nil if the rep wasn't graded.
    public var range: String?
    /// "straight", "hips low", "hips high", "unseen"; nil if the rep wasn't graded.
    public var back: String?
    public var complete: Bool
    public var straight: Bool
}

extension Rep {
    public func row(metric: Metric) -> RepRow {
        RepRow(id: number, startSeconds: descentTime, downSeconds: eccentricSeconds, pauseSeconds: pauseSeconds,
               pushUpSeconds: seconds(metric), range: grade?.reason, back: grade?.backLabel,
               complete: complete, straight: straight)
    }
}
