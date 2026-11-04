import Accelerate
import Charts
import SwiftUI

// The panel under the clip: the set's tallies, the shoulder's height and the body line over time, and each
// rep's push-up time. Swift Charts with its own axes, system fonts and colours, in light and dark. A grade is
// shown by a symbol and a legend as well as by colour. During a set it shows the reps so far; afterwards
// the whole set, with the playhead.

/// What the panel's header shows: the reps locked out by `frame`.
public struct PanelState: Sendable, Equatable {
    public var frame: Int
    /// Reps locked out by `frame`.
    public var done: [Rep]
    /// Their mean push-up time, by the metric; nil before the first.
    public var averageSeconds: Double?
    public var full: Int
    public var straight: Int
    public var graded: Int
}

extension RepCounter {
    public func panelState(atFrame frame: Int, metric: Metric) -> PanelState {
        let done = done(at: frame)
        return PanelState(frame: frame, done: done, averageSeconds: RepSummary(done, metric: metric)?.meanSeconds,
                          full: done.count(where: \.complete), straight: done.count(where: \.straight), graded: done.count)
    }
}

/// The panel for the counter so far, with `settings`. `playhead` is the frame on screen while a clip plays;
/// nil while counting live, when the newest frame is now.
public struct PanelView: View {
    let counter: RepCounter
    let settings: Settings
    let playhead: Int?

    public init(counter: RepCounter, settings: Settings, playhead: Int?) {
        (self.counter, self.settings, self.playhead) = (counter, settings, playhead)
    }

    /// The set's frames so far: the whole clip, or up to now.
    private var duration: Double { max(counter.times.last ?? 0, 1) }

    /// The whole set so far: every rep counted.
    private var state: PanelState {
        counter.panelState(atFrame: .max, metric: settings.metric)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GeometryReader { geometry in
                HStack(spacing: 12) {
                    VStack(spacing: 12) {
                        GroupBox("Shoulder height, in arm lengths") { heightChart }
                        GroupBox("Body line, in degrees") { lineChart }
                    }
                    GroupBox("Push-up time per rep, in seconds") { timesChart }
                        .frame(width: geometry.size.width * 0.3)
                }
            }
        }
        .padding()
    }

    // MARK: Header

    private var header: some View {
        let state = state
        return HStack(alignment: .firstTextBaseline, spacing: 32) {
            stat("Push-ups") { Text(state.done.count, format: .number) }
            stat("Average push-up time") {
                if let average = state.averageSeconds { Text(seconds(average)) } else { Text("—").foregroundStyle(.secondary) }
            }
            stat("Full range") { tally(state.full, of: state.graded) }
            stat("Straight back") { tally(state.straight, of: state.graded) }
            Spacer(minLength: 0)
        }
    }

    private func stat(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value().font(.title2.weight(.semibold)).monospacedDigit()
        }
    }

    /// "2 of 3", with a check when every rep passed and a cross when one didn't.
    @ViewBuilder
    private func tally(_ n: Int, of graded: Int) -> some View {
        if graded == 0 {
            Text("—").foregroundStyle(.secondary)
        } else {
            let all = n == graded
            Label {
                Text("\(n) of \(graded)")
            } icon: {
                Image(systemName: all ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(all ? .green : .red)
            }
        }
    }

    // MARK: Charts

    /// A series' frames as (time, value, run): a run breaks where the value is missing, so the line breaks
    /// there too.
    private func points(_ series: [Double]) -> [(time: Double, value: Double, run: Int)] {
        let times = counter.times
        var run = 0, out: [(Double, Double, Int)] = []
        for i in 0..<min(series.count, times.count) {
            if series[i].isFinite { out.append((times[i], series[i], run)) } else { run += 1 }
        }
        return out
    }

    /// When frame `frame` is shown, seconds.
    private func time(_ frame: Int) -> Double { counter.times[min(frame, counter.times.count - 1)] }

    @ChartContentBuilder
    private var playheadMark: some ChartContent {
        if let playhead {
            RuleMark(x: .value("Now", time(playhead)))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    /// The shoulder's height above the wrist, as the grade reads it, with the up and floor lines; each rep's
    /// deepest point and lockout marked by whether it got there.
    private var heightChart: some View {
        let up = settings.romUpFraction * counter.top, floor = settings.romDownHeight
        let height = displaySmoothed(counter.heightReading, times: counter.times)
        let seen = height.filter(\.isFinite)
        let low = min(seen.min() ?? floor, floor) - 0.1, high = max(seen.max() ?? 1, up.isFinite ? up : 1) + 0.1
        let marks = counter.reps.flatMap { rep in
            [(rep.bottomFrame, rep.grade.bottomOK ? "Reached" : "Short"),
             (rep.lockoutFrame, rep.grade.topOK ? "Reached" : "Short")]
        }.compactMap { frame, label in
            frame < height.count && height[frame].isFinite ? (time: time(frame), value: height[frame], label: label) : nil
        }
        return Chart {
            ForEach(Array(points(height).enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Arm lengths", point.value),
                         series: .value("Run", point.run))
                    .foregroundStyle(.tint)
            }
            if up.isFinite {
                RuleMark(y: .value("Up", up))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("Up").font(.caption).foregroundStyle(.secondary) }
            }
            RuleMark(y: .value("Floor", floor))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .bottom, alignment: .leading) { Text("Floor").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                PointMark(x: .value("Time", mark.time), y: .value("Arm lengths", mark.value))
                    .foregroundStyle(by: .value("Grade", mark.label))
                    .symbol(by: .value("Grade", mark.label))
            }
            playheadMark
        }
        .chartForegroundStyleScale(["Reached": Color.green, "Short": Color.red])
        .chartSymbolScale(["Reached": .circle, "Short": .cross])
        .chartLegend(position: .top, alignment: .trailing)
        .chartXScale(domain: 0...duration)
        .chartYScale(domain: low...high)
        .chartXAxis { AxisMarks { _ in AxisGridLine() } }
    }

    /// The body line, with the band it may bend within; where it leaves the band the line is heavier, and the
    /// band's edges say which way.
    private var lineChart: some View {
        let tolerance = settings.backToleranceDegrees
        let line = displaySmoothed(counter.lineReading, times: counter.times)
        let shown = points(line)
        // Red where the grade's own reading is past the tolerance, drawn along the smoothed line: the smoothing
        // rounds off a peak by up to a degree or so, which would hide a bend the grade counts.
        let bent = points(line.indices.map { abs(counter.lineReading[$0]) > tolerance ? line[$0] : .nan })
        // Fit to the set, so getting up off the floor afterwards doesn't stretch the axis.
        let set = counter.reps.first.map { time($0.descentFrame)...time(counter.reps[counter.reps.count - 1].lockoutFrame) }
        let inSet = shown.filter { set?.contains($0.time) ?? true }.map(\.value)
        let low = min(inSet.min() ?? -tolerance, -tolerance) - 3, high = max(inSet.max() ?? tolerance, tolerance) + 3
        return Chart {
            RectangleMark(xStart: .value("Start", 0), xEnd: .value("End", duration),
                          yStart: .value("Low", -tolerance), yEnd: .value("High", tolerance))
                .foregroundStyle(Color.green.opacity(0.12))
            RuleMark(y: .value("Straight", 0))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("Hips high", tolerance))
                .foregroundStyle(.clear)
                .annotation(position: .bottom, alignment: .leading) { Text("Hips high").font(.caption).foregroundStyle(.secondary) }
            RuleMark(y: .value("Hips low", -tolerance))
                .foregroundStyle(.clear)
                .annotation(position: .top, alignment: .leading) { Text("Hips low").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Degrees", min(high, max(low, point.value))),
                         series: .value("Run", "line \(point.run)"))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(Array(bent.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Degrees", min(high, max(low, point.value))),
                         series: .value("Run", "bent \(point.run)"))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            playheadMark
        }
        .chartXScale(domain: 0...duration)
        .chartYScale(domain: low...high)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel { if let t = value.as(Double.self) { Text(seconds(t, digits: 0)) } }
            }
        }
    }

    /// Each rep's push-up time, marked by its grade, and the average.
    private var timesChart: some View {
        let state = state
        let reps = state.done
        return Chart {
            if let average = state.averageSeconds {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) { Text("Average").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(reps, id: \.number) { rep in
                LineMark(x: .value("Rep", rep.number), y: .value("Seconds", rep.seconds(settings.metric)))
                    .foregroundStyle(.tint)
            }
            ForEach(reps, id: \.number) { rep in
                PointMark(x: .value("Rep", rep.number), y: .value("Seconds", rep.seconds(settings.metric)))
                    .foregroundStyle(by: .value("Grade", label(rep)))
                    .symbol(by: .value("Grade", label(rep)))
                    .symbolSize(80)
            }
        }
        .chartForegroundStyleScale(["Good": Color.green, "Short": Color.red, "Bent": Color.orange, "Short and bent": Color.purple])
        .chartSymbolScale(["Good": .circle, "Short": .cross, "Bent": .triangle, "Short and bent": .diamond])
        .chartLegend(position: .top, alignment: .leading)
        .chartXScale(domain: 0.5...(Double(max(counter.count, 1)) + 0.5))
        .chartXAxis { AxisMarks(values: Array(1...max(counter.count, 1))) { value in
            AxisGridLine()
            AxisValueLabel { if let n = value.as(Int.self) { Text("Rep \(n)") } }
        } }
    }

    private func label(_ rep: Rep) -> String {
        switch (rep.complete, rep.straight) {
        case (true, true): "Good"
        case (false, true): "Short"
        case (true, false): "Bent"
        case (false, false): "Short and bent"
        }
    }
}

/// Seconds with the reader's decimal separator, as the sidebar writes them ("0.96 s", "0,96 s").
private func seconds(_ value: Double, digits: Int = 2) -> String {
    value.formatted(.number.precision(.fractionLength(digits))) + " s"
}

/// How much the panel's curves are smoothed, for display only: a Gaussian's σ, in seconds. At 80 ms the grade's
/// readings, a 5-frame median, lose their steps and come out as smooth at 24, 30 and 60 fps (measured on the six
/// test clips); a rep's marks move by at most 0.03 arm lengths.
let displaySmoothingSeconds = 0.08

/// `series`, a value a frame for the frames shown at `times`, smoothed for display by a Gaussian of `sigma` seconds,
/// so the curves look alike at any frame rate. A frame without a value stays without one, and the others are
/// smoothed over the frames around them that have one: Accelerate convolves the values (0 where there's none) and
/// the frames that have one, and the one is divided by the other.
func displaySmoothed(_ series: [Double], times: [Double], sigma: Double = displaySmoothingSeconds) -> [Double] {
    guard series.count > 1, times.count > 1, let first = times.first, let last = times.last, last > first else {
        return series
    }
    let spread = sigma * Double(times.count - 1) / (last - first)   // σ in frames, at the clip's mean frame rate
    let half = Int((3 * spread).rounded(.up))
    guard half > 0 else { return series }
    let kernel = (-half...half).map { exp(-0.5 * pow(Double($0) / spread, 2)) }
    let pad = [Double](repeating: 0, count: half)
    var sums = [Double](repeating: 0, count: series.count)
    var weights = [Double](repeating: 0, count: series.count)
    vDSP.convolve(pad + series.map { $0.isFinite ? $0 : 0 } + pad, withKernel: kernel, result: &sums)
    vDSP.convolve(pad + series.map { $0.isFinite ? 1 : 0 } + pad, withKernel: kernel, result: &weights)
    return series.indices.map { series[$0].isFinite ? sums[$0] / weights[$0] : .nan }
}
