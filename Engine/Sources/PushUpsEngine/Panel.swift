import Accelerate
import Charts
import SwiftUI

// The demo's panel (`src/panel.py`), under the clip: the tallies so far, the shoulder's height and
// the body line over time up to the playhead, and each rep's push-up time as it locks out. The
// axes are fixed for the whole clip, so nothing rescales as it plays. Swift Charts draws what the
// demo draws with matplotlib and OpenCV; the sizes are the demo's, in pixels of a 1280-wide panel.

/// What the panel's header shows at one frame: only the reps locked out by then count, as in the demo.
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

extension RepAnalysis {
    public func panelState(atSourceFrame frame: Int, metric: Metric) -> PanelState {
        let done = done(at: frame)
        let graded = done.compactMap(\.grade)
        return PanelState(frame: frame, done: done, averageSeconds: RepSummary(done, metric: metric)?.meanSeconds,
                          full: graded.count { $0.complete }, straight: graded.count { $0.backOK }, graded: graded.count)
    }

    /// The demo's `on_source_frames`: a series by returned frame, spread onto `count` source frames,
    /// NaN on the frames without a person.
    func onSourceFrames(_ series: [Double], count: Int) -> [Double] {
        var out = [Double](repeating: .nan, count: count)
        for (i, frame) in indices.enumerated() where frame < count { out[frame] = series[i] }
        return out
    }
}

/// The demo's `PANEL_SMOOTH_SECONDS`: the panel's curves are smoothed this much for display only.
let panelSmoothSeconds = 0.08

/// The demo's `display_smooth`: a centred Gaussian of `seconds` sigma, over the series with its gaps
/// filled; gaps inside it up to `bridgeSeconds` are bridged, longer ones (and the ends) stay NaN.
func displaySmooth(_ values: [Double], fps: Double, seconds: Double, bridgeSeconds: Double = 0.1) -> [Double] {
    let finite = values.map(\.isFinite)
    guard finite.count(where: { $0 }) >= 2 else { return values }
    var filled = fillGaps(values)
    var keep = finite
    let limit = max(1, Int((bridgeSeconds * fps).rounded(.toNearestOrEven)))
    var i = 0
    while i < values.count {
        guard !finite[i] else { i += 1; continue }
        var j = i
        while j < values.count, !finite[j] { j += 1 }
        if i > 0, j < values.count, j - i <= limit { keep.replaceSubrange(i..<j, with: repeatElement(true, count: j - i)) }
        i = j
    }
    let sigma = seconds * fps
    if sigma >= 0.5, filled.count >= 3 {
        let half = Int(3 * sigma)
        let weights = (-half...half).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
        let total = weights.reduce(0, +)
        let padded = [Double](repeating: filled[0], count: half) + filled + [Double](repeating: filled[filled.count - 1], count: half)
        // Display only, so Accelerate's sum order is fine here (the analysis's filters can't use it).
        var smoothed = [Double](repeating: 0, count: filled.count)
        vDSP.convolve(padded, withKernel: weights.map { $0 / total }, result: &smoothed)
        filled = smoothed
    }
    return zip(keep, filled).map { $0 ? $1 : .nan }
}

/// The panel with the playhead on source frame `playhead`, for the analysis with `settings`, sized by
/// its container: text and marks scale with the width, as the demo's do.
public struct PanelView: View {
    let analysis: RepAnalysis
    let settings: Settings
    let fps: Double
    let duration: Double
    let playhead: Int
    /// The shoulder's height and the body line on every source frame, smoothed for display.
    let height: [Double]
    let line: [Double]

    /// `frames` is the clip's source frame count, `fps` what its frames are timed by.
    public init(analysis: RepAnalysis, settings: Settings, fps: Double, frames: Int, playhead: Int) {
        (self.analysis, self.settings, self.fps, self.playhead) = (analysis, settings, fps, playhead)
        duration = Double(frames) / fps
        height = displaySmooth(analysis.onSourceFrames(analysis.raw, count: frames), fps: fps, seconds: panelSmoothSeconds)
        line = displaySmooth(analysis.onSourceFrames(analysis.line, count: frames), fps: fps, seconds: panelSmoothSeconds)
    }

    // The demo's palette, shared with the other vision-demos panels.
    nonisolated static let background = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1a / 255)
    nonisolated static let foreground = Color(red: 0xf2 / 255, green: 0xf4 / 255, blue: 0xf7 / 255)
    nonisolated static let muted = Color(red: 0x8b / 255, green: 0x91 / 255, blue: 0x99 / 255)
    nonisolated static let grid = Color(red: 0x2b / 255, green: 0x30 / 255, blue: 0x38 / 255)
    nonisolated static let accent = Color(red: 0x28 / 255, green: 0xa0 / 255, blue: 0xff / 255)

    public var body: some View {
        GeometryReader { geometry in
            let (w, h) = (geometry.size.width, geometry.size.height)
            let s = w / 1280, m = 28 * s
            let state = analysis.panelState(atSourceFrame: playhead, metric: settings.metric)
            // The demo's split: the two columns' plot areas come out the same width.
            let (leftPad, rightPad, gap) = (112 * s, 62 * s, 16 * s)
            let split = (w + leftPad + gap - rightPad - m) / 2
            let top = h * 0.17 + 6 * s, floor = h - 8 * s
            let mid = (top + floor) / 2 - 8 * s
            VStack(spacing: 0) {
                header(state, w: w, h: h, s: s, m: m)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        heightChart(s, labelWidth: leftPad - 12 * s).frame(height: mid - top)
                        lineChart(s, labelWidth: leftPad - 12 * s).frame(height: floor - mid)
                    }
                    .padding(.trailing, gap)
                    .frame(width: split)
                    timesChart(state, s, labelWidth: rightPad - 12 * s)
                        .padding(.trailing, m)
                }
                .padding(.top, 6 * s)
                .padding(.bottom, 8 * s)
            }
            .frame(width: w, height: h, alignment: .top)
            .background(Self.background)
            .foregroundStyle(Self.foreground)
        }
    }

    private func header(_ state: PanelState, w: CGFloat, h: CGFloat, s: CGFloat, m: CGFloat) -> some View {
        func tally(_ n: Int) -> (String, Color) {
            state.graded == 0 ? ("—", Self.muted) : ("\(n) / \(state.graded)", n == state.graded ? OverlayView.good : OverlayView.bad)
        }
        let cells: [(label: String, value: String, color: Color, size: CGFloat)] = [
            ("PUSH-UPS", "\(state.done.count)", Self.foreground, 40),
            ("AVG PUSH-UP TIME", state.averageSeconds.map { seconds($0, 2) } ?? "—",
             state.averageSeconds == nil ? Self.muted : Self.accent, 28),
            (label: "FULL RANGE", value: tally(state.full).0, color: tally(state.full).1, size: 28),
            (label: "STRAIGHT BACK", value: tally(state.straight).0, color: tally(state.straight).1, size: 28),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(cells.indices, id: \.self) { i in
                let x = m + (w - 2 * m) * (CGFloat(i) + 0.5) / 4
                Text(cells[i].label).font(.system(size: 18 * s, weight: .medium)).foregroundStyle(Self.muted)
                    .position(x: x, y: h * 0.05)
                Text(cells[i].value).font(.system(size: cells[i].size * s, weight: .bold).monospacedDigit())
                    .foregroundStyle(cells[i].color)
                    .position(x: x, y: h * 0.115)
            }
            Rectangle().fill(Self.grid).frame(width: w - 2 * m, height: max(1, s)).position(x: w / 2, y: h * 0.17)
        }
        .frame(width: w, height: h * 0.17 + max(1, s), alignment: .topLeading)
    }

    /// The source frames up to the playhead, as (time, value, run): a run breaks where the value is NaN.
    private func shown(_ series: [Double]) -> [(time: Double, value: Double, run: Int)] {
        var run = 0, out: [(Double, Double, Int)] = []
        for frame in 0...min(playhead, series.count - 1) {
            if series[frame].isFinite { out.append((Double(frame) / fps, series[frame], run)) } else { run += 1 }
        }
        return out
    }

    /// A tick label: 10 pt at the demo's dpi, in a fixed width so stacked graphs share a left edge.
    private func tick(_ text: String, _ s: CGFloat, width: CGFloat? = nil) -> some View {
        Text(text).font(.system(size: 13.9 * s)).foregroundStyle(Self.muted)
            .frame(width: width, alignment: .trailing)
    }

    /// The demo's axes: a left and a bottom spine, nothing else, and the title over the plot's left
    /// edge (matplotlib's 15 pt at the demo's 100 × scale dpi). The chart leaves `titleRoom` for it.
    private func plotArea(_ plot: ChartPlotContent, _ s: CGFloat, title: String) -> some View {
        plot.overlay(alignment: .leading) { Rectangle().fill(Self.grid).frame(width: max(1, s)) }
            .overlay(alignment: .bottom) { Rectangle().fill(Self.grid).frame(height: max(1, s)) }
            .overlay(alignment: .topLeading) {
                Text(title).font(.system(size: 20.8 * s, weight: .medium)).fixedSize()
                    .alignmentGuide(.top) { $0[.bottom] + 6 * s }
            }
    }

    private func titleRoom(_ s: CGFloat) -> CGFloat { 30 * s }

    private func thick(_ s: CGFloat) -> CGFloat { max(2, (2.4 * s).rounded(.down)) }

    private func heightChart(_ s: CGFloat, labelWidth: CGFloat) -> some View {
        // The two lines are the cutoffs themselves, by name: each rep's dots land on the side of
        // them its grade says.
        let up = settings.romUpFraction * analysis.top, down = settings.romDownHeight
        let seen = height.filter(\.isFinite)
        let low = min(seen.min() ?? down, down), high = max(seen.max() ?? analysis.top, up)
        let pad = (high - low) * 0.07
        let last = height.count - 1
        let dots = analysis.reps.flatMap { rep in
            [(rep.pushFrame, rep.grade?.bottomOK ?? true), (rep.lockoutFrame, rep.grade?.topOK ?? true)]
        }.filter { $0.0 <= playhead }.map { f, ok in (Double(f) / fps, height[min(f, last)], ok ? OverlayView.good : OverlayView.bad) }
        let now = min(playhead, last)
        return Chart {
            ForEach([up, down], id: \.self) { y in
                RuleMark(y: .value("Cutoff", y)).foregroundStyle(Self.muted.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.67 * s, dash: [5 * s, 3 * s]))
            }
            ForEach(Array(shown(height).enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Height", point.value), series: .value("Run", point.run))
                    .foregroundStyle(Self.accent).lineStyle(StrokeStyle(lineWidth: thick(s)))
            }
            RuleMark(x: .value("Now", Double(playhead) / fps)).foregroundStyle(Self.muted)
                .lineStyle(StrokeStyle(lineWidth: max(1, (1.2 * s).rounded(.down))))
            ForEach(Array((dots + [(Double(now) / fps, height[now], Self.accent)]).enumerated()), id: \.offset) { i, dot in
                if dot.1.isFinite {
                    let r: CGFloat = i == dots.count ? 6 : 5
                    PointMark(x: .value("Time", dot.0), y: .value("Height", dot.1))
                        .foregroundStyle(Self.background).symbolSize(pow(2 * (r + 1.5) * s, 2))
                    PointMark(x: .value("Time", dot.0), y: .value("Height", dot.1))
                        .foregroundStyle(dot.2).symbolSize(pow(2 * r * s, 2))
                }
            }
        }
        .chartXScale(domain: 0...duration)
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [down, up]) { value in
                AxisTick(length: 3 * s, stroke: StrokeStyle(lineWidth: max(1, s))).foregroundStyle(Self.muted)
                AxisValueLabel { tick(value.as(Double.self) == up ? "up" : "floor", s, width: labelWidth) }
            }
        }
        .chartPlotStyle { plotArea($0, s, title: "Vertical displacement") }
        .padding(.top, titleRoom(s))
    }

    private func lineChart(_ s: CGFloat, labelWidth: CGFloat) -> some View {
        let tolerance = settings.backToleranceDegrees
        // Fit to the set itself, so getting up off the floor afterwards doesn't stretch the axis;
        // it's clipped to the edge instead.
        let inSet = (analysis.reps.first.map { first in
            Array(line[first.descentFrame...min(analysis.reps.last!.lockoutFrame, line.count - 1)])
        } ?? line).filter(\.isFinite)
        let low = min(inSet.min() ?? -tolerance, -tolerance), high = max(inSet.max() ?? tolerance, tolerance)
        let pad = (high - low) * 0.08
        let clip = { (v: Double) in min(high + pad, max(low - pad, v)) }
        let points = shown(line)
        // Red where it leaves the band, so the bend shows where it happens.
        let bent = shown(line.map { abs($0) > tolerance ? $0 : .nan })
        let now = min(playhead, line.count - 1)
        let span = duration
        let step: Double = span > 40 ? 10 : span > 12 ? 5 : 1
        return Chart {
            RectangleMark(xStart: .value("Start", 0), xEnd: .value("End", duration),
                          yStart: .value("Low", -tolerance), yEnd: .value("High", tolerance))
                .foregroundStyle(OverlayView.good.opacity(0.08))
            RuleMark(y: .value("Straight", 0)).foregroundStyle(Self.muted.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.67 * s, dash: [5 * s, 3 * s]))
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Degrees", clip(point.value)), series: .value("Run", "line \(point.run)"))
                    .foregroundStyle(Self.foreground).lineStyle(StrokeStyle(lineWidth: thick(s) - 1))
            }
            ForEach(Array(bent.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Degrees", clip(point.value)), series: .value("Run", "bent \(point.run)"))
                    .foregroundStyle(OverlayView.bad).lineStyle(StrokeStyle(lineWidth: thick(s)))
            }
            RuleMark(x: .value("Now", Double(playhead) / fps)).foregroundStyle(Self.muted)
                .lineStyle(StrokeStyle(lineWidth: max(1, (1.2 * s).rounded(.down))))
            if line[now].isFinite {
                PointMark(x: .value("Time", Double(now) / fps), y: .value("Degrees", clip(line[now])))
                    .foregroundStyle(Self.background).symbolSize(pow(13 * s, 2))
                PointMark(x: .value("Time", Double(now) / fps), y: .value("Degrees", clip(line[now])))
                    .foregroundStyle(abs(line[now]) > tolerance ? OverlayView.bad : Self.foreground).symbolSize(pow(10 * s, 2))
            }
        }
        .chartXScale(domain: 0...duration)
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: duration, by: step))) { value in
                AxisTick(length: 3 * s, stroke: StrokeStyle(lineWidth: max(1, s))).foregroundStyle(Self.muted)
                AxisValueLabel { tick(String(format: "%.0fs", value.as(Double.self) ?? 0), s) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [-tolerance, 0, tolerance]) { value in
                let v = value.as(Double.self) ?? 0
                AxisTick(length: 3 * s, stroke: StrokeStyle(lineWidth: max(1, s))).foregroundStyle(Self.muted)
                AxisValueLabel {
                    tick(abs(v) < 1e-6 ? "straight" : "hips \(v < 0 ? "low" : "high") \(String(format: "%.0f", abs(v)))°", s, width: labelWidth)
                }
            }
        }
        .chartPlotStyle { plotArea($0, s, title: "Body line vs. straight line") }
        .padding(.top, titleRoom(s))
    }

    private func timesChart(_ state: PanelState, _ s: CGFloat, labelWidth: CGFloat) -> some View {
        let values = analysis.reps.map { $0.seconds(settings.metric) }
        let n = max(values.count, 1)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let span = max(high - low, 0.1)
        let (yLow, yHigh) = (max(0, low - span * 0.15), high + span * 0.3)
        // About five ticks, on a round step; two decimals where the step has two (the demo prints 0.75 as "0.8s").
        let step = [0.05, 0.1, 0.2, 0.25, 0.5, 1, 2].first { (yHigh - yLow) / $0 <= 6 } ?? 2
        let ticks = Array(stride(from: (yLow / step).rounded(.up) * step, to: yHigh, by: step))
        let done = state.done.map { (number: $0.number, seconds: $0.seconds(settings.metric), straight: $0.straight, complete: $0.complete) }
        let dot = 7 * s
        return Chart {
            if let average = state.averageSeconds {
                RuleMark(y: .value("Mean", average)).foregroundStyle(Self.muted)
                    .lineStyle(StrokeStyle(lineWidth: max(1, s.rounded(.down)), dash: [6 * s, 6 * s]))
            }
            ForEach(done, id: \.number) { rep in
                LineMark(x: .value("Rep", rep.number), y: .value("Seconds", rep.seconds))
                    .foregroundStyle(Self.accent).lineStyle(StrokeStyle(lineWidth: thick(s) - 1))
            }
            ForEach(done, id: \.number) { rep in
                PointMark(x: .value("Rep", rep.number), y: .value("Seconds", rep.seconds))
                    .foregroundStyle(rep.complete ? Self.background : Self.foreground).symbolSize(pow(2 * (dot + 2 * s), 2))
                if !rep.complete {
                    // The ring around a rep that missed its range: the halo, minus its inner stroke.
                    PointMark(x: .value("Rep", rep.number), y: .value("Seconds", rep.seconds))
                        .foregroundStyle(Self.background).symbolSize(pow(2 * (dot + 2 * s - max(1, s)), 2))
                }
                PointMark(x: .value("Rep", rep.number), y: .value("Seconds", rep.seconds))
                    .foregroundStyle(rep.straight ? Self.accent : OverlayView.bad).symbolSize(pow(2 * dot, 2))
                    .annotation(position: .top, spacing: 8 * s) {
                        if rep.number == done.last?.number {
                            Text(seconds(rep.seconds, 2)).font(.system(size: 14 * s, weight: .medium))
                                .foregroundStyle(Self.foreground)
                        }
                    }
            }
        }
        .chartXScale(domain: 0.4...(Double(n) + 0.6))
        .chartYScale(domain: yLow...yHigh)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 1, through: n, by: max(1, (n + 11) / 12)))) { value in
                AxisTick(length: 3 * s, stroke: StrokeStyle(lineWidth: max(1, s))).foregroundStyle(Self.muted)
                AxisValueLabel { tick("\(value.as(Int.self) ?? 0)", s) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { value in
                AxisTick(length: 3 * s, stroke: StrokeStyle(lineWidth: max(1, s))).foregroundStyle(Self.muted)
                AxisValueLabel { tick(seconds(value.as(Double.self) ?? 0, step < 0.1 || step == 0.25 ? 2 : 1), s, width: labelWidth) }
            }
        }
        .chartPlotStyle { plotArea($0, s, title: "Push-up time per rep") }
        .padding(.top, titleRoom(s))
    }
}

/// Seconds with the reader's decimal separator, as the app's sidebar writes them ("0.96s", "0,96s").
private func seconds(_ value: Double, _ digits: Int) -> String {
    value.formatted(.number.precision(.fractionLength(digits))) + "s"
}

extension PanelView {
    /// The panel at `width` × `height`, through SwiftUI's `ImageRenderer`.
    @MainActor
    public func rendered(width: Int, height: Int) -> CGImage? {
        let renderer = ImageRenderer(content: frame(width: CGFloat(width), height: CGFloat(height)))
        renderer.scale = 1
        return renderer.cgImage
    }
}
