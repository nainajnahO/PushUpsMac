import AppKit
import Charts
import SwiftUI

// Your push-ups over time. The app keeps each set as it ends. This gathers the sets by day and by each rep's
// place in its set, and draws the Progress tab's dashboard from them.

/// A counted rep as the history keeps it: its times in its set and its grade. A type of its own rather than
/// `Rep`, so what's stored stays the same as the counter's working fields change. Its number is its place in
/// its set.
public struct SavedRep: Codable, Sendable, Equatable {
    /// Seconds from the set's first frame.
    public var descentTime: Double
    public var bottomTime: Double
    public var pushTime: Double
    public var lockoutTime: Double
    public var bottomOK: Bool
    public var topOK: Bool
    public var backOK: Bool

    /// Full range of motion.
    public var complete: Bool { bottomOK && topOK }
    /// "full", or what fell short of it, as ``Grade/reason``.
    public var reason: String { rangeReason(bottomOK: bottomOK, topOK: topOK) }

    /// The push-up time `metric` reports, as ``Rep/seconds(_:)``.
    public func seconds(_ metric: Metric) -> Double {
        lockoutTime - (metric == .moving ? pushTime : bottomTime)
    }

    /// The same rep, `seconds` later: as it sits in a set that started that much earlier.
    func shifted(by seconds: Double) -> SavedRep {
        var rep = self
        rep.descentTime += seconds
        rep.bottomTime += seconds
        rep.pushTime += seconds
        rep.lockoutTime += seconds
        return rep
    }
}

extension SavedRep {
    public init(_ rep: Rep) {
        self.init(descentTime: rep.descentTime, bottomTime: rep.bottomTime, pushTime: rep.pushTime,
                  lockoutTime: rep.lockoutTime, bottomOK: rep.grade.bottomOK, topOK: rep.grade.topOK,
                  backOK: rep.grade.backOK)
    }
}

/// A set in the history: when it started, and its reps, at least one.
public struct PastSet: Sendable, Equatable {
    public var start: Date
    public var reps: [SavedRep]

    public init(start: Date, reps: [SavedRep]) {
        (self.start, self.reps) = (start, reps)
    }

    /// Sets that were one, joined: from the first one's start, each set's reps at their times from there.
    public static func merged(_ sets: [PastSet]) -> PastSet? {
        let sets = sets.sorted { $0.start < $1.start }
        guard let first = sets.first else { return nil }
        return PastSet(start: first.start, reps: sets.flatMap { set in
            set.reps.map { $0.shifted(by: set.start.timeIntervalSince(first.start)) }
        })
    }
}

/// The history gathered: day by day, by rep number, and the totals.
public struct Training: Sendable, Equatable {
    /// A day's sets.
    public struct Day: Sendable, Equatable {
        /// Its start, in the calendar's time zone.
        public var day: Date
        public var sets: Int
        public var reps: Int
        /// Shares of the day's reps, 0–1.
        public var full: Double
        public var straight: Double
        /// The mean push-up time, seconds.
        public var seconds: Double
        /// The same three over the seven days up to and including this one, rep by rep: what the charts draw,
        /// as a single day's few sets swing too much to read a trend from.
        public var weekFull: Double
        public var weekStraight: Double
        public var weekSeconds: Double
    }

    /// The reps at one place in their sets, such as every set's rep 1, across the history.
    public struct Place: Sendable, Equatable {
        public var number: Int
        /// The sets that got this far.
        public var sets: Int
        public var full: Double
        public var straight: Double
        public var seconds: Double
    }

    public var calendar: Calendar
    /// Oldest first.
    public var days: [Day]
    /// Rep 1 on, as far as ``fewestSets`` sets got: past that one or two long sets would swing the line.
    public var places: [Place]
    /// A tenth of the sets, and at least three, or every set while there are fewer.
    public var fewestSets: Int
    public var reps: Int
    /// The most reps in one set.
    public var biggestSet: Int
    /// Reps in the calendar week of `now`, and in the week before.
    public var weekReps: Int
    public var lastWeekReps: Int
    /// Days in a row with a set, up to today, or up to yesterday before today's first set.
    public var streak: Int
    /// The shares of the reps over the last seven days, today included: nil without a set in them.
    public var recentFull: Double?
    public var recentStraight: Double?
    /// What the day-by-day charts span: at least the last four weeks, to the end of today.
    public var span: ClosedRange<Date>

    /// The history `sets`, with push-up times by `metric`, as of `now`.
    public init(_ sets: [PastSet], metric: Metric, now: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        let byDay = Dictionary(grouping: sets) { calendar.startOfDay(for: $0.start) }
        /// The reps of the seven days up to and including `day`.
        func week(to day: Date) -> [SavedRep] {
            (0..<7).flatMap { byDay[calendar.date(byAdding: .day, value: -$0, to: day)!]?.flatMap(\.reps) ?? [] }
        }
        days = byDay.keys.sorted().map { day in
            let reps = byDay[day]!.flatMap(\.reps), week = week(to: day)
            return Day(day: day, sets: byDay[day]!.count, reps: reps.count, full: share(reps, \.complete),
                       straight: share(reps, \.backOK), seconds: mean(reps.map { $0.seconds(metric) }),
                       weekFull: share(week, \.complete), weekStraight: share(week, \.backOK),
                       weekSeconds: mean(week.map { $0.seconds(metric) }))
        }
        biggestSet = sets.map(\.reps.count).max() ?? 0
        let fewest = max(min(3, sets.count), sets.count / 10)
        fewestSets = fewest
        places = (0..<biggestSet).map { i in
            let reps = sets.compactMap { $0.reps.indices.contains(i) ? $0.reps[i] : nil }
            return Place(number: i + 1, sets: reps.count, full: share(reps, \.complete), straight: share(reps, \.backOK),
                         seconds: mean(reps.map { $0.seconds(metric) }))
        }
        .prefix { $0.sets >= fewest }
        reps = sets.reduce(0) { $0 + $1.reps.count }
        func repsInWeek(of date: Date) -> Int {
            let week = calendar.dateInterval(of: .weekOfYear, for: date)
            return sets.filter { week?.contains($0.start) == true }.reduce(0) { $0 + $1.reps.count }
        }
        weekReps = repsInWeek(of: now)
        lastWeekReps = repsInWeek(of: calendar.date(byAdding: .weekOfYear, value: -1, to: now)!)
        let today = calendar.startOfDay(for: now)
        let recent = week(to: today)
        (recentFull, recentStraight) = recent.isEmpty ? (nil, nil) : (share(recent, \.complete), share(recent, \.backOK))
        let fourWeeksAgo = calendar.date(byAdding: .day, value: -27, to: today)!
        span = min(days.first?.day ?? today, fourWeeksAgo)...calendar.date(byAdding: .day, value: 1, to: today)!
        var day = today
        if byDay[day] == nil { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while byDay[day] != nil {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        self.streak = streak
    }
}

/// The share of `reps` that passed, 0–1.
private func share(_ reps: [SavedRep], _ passed: KeyPath<SavedRep, Bool>) -> Double {
    Double(reps.count { $0[keyPath: passed] }) / Double(reps.count)
}

/// The Progress tab's dashboard: this week and the figures beside it, then day by day, then rep by rep within a
/// set. Hovering a chart shows the day or the rep under the pointer, in every chart of its row.
public struct TrainingView: View {
    let training: Training
    @State private var hoveredDay: Date?
    @State private var hoveredRep: Int?

    public init(training: Training) {
        self.training = training
    }

    public var body: some View {
        if training.days.isEmpty {
            ContentUnavailableView("No Sets Yet", systemImage: "chart.bar",
                                   description: Text("Count a set with the camera, and it shows up here once the camera is off."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    VStack(alignment: .leading, spacing: 12) {
                        section("Day by Day", "Form and push-up time are averaged over the seven days up to each day.")
                        GroupBox("Push-ups per day") { volumeChart }
                        HStack(alignment: .top, spacing: 12) {
                            GroupBox("Form, % of reps") { formByDay }
                            GroupBox("Push-up time, in seconds") { timeByDay }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        section("Within a Set", "Each rep number across your sets, as far as \(training.fewestSets) or more sets got.")
                        HStack(alignment: .top, spacing: 12) {
                            GroupBox("Form by rep number, % of reps") { formByPlace }
                            GroupBox("Push-up time by rep number, in seconds") { timeByPlace }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    // MARK: Figures

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 40) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This week").font(.subheadline).foregroundStyle(.secondary)
                Text(training.weekReps, format: .number).font(.system(size: 52, weight: .semibold))
                Text("\(training.lastWeekReps.formatted()) last week").font(.subheadline).foregroundStyle(.secondary)
            }
            figure("Days in a row", training.streak.formatted())
            figure("Full range", percent(training.recentFull), "last 7 days")
            figure("Straight back", percent(training.recentStraight), "last 7 days")
            figure("Biggest set", training.biggestSet.formatted())
            figure("All push-ups", training.reps.formatted())
            Spacer(minLength: 0)
        }
    }

    private func figure(_ title: String, _ value: String, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.semibold))
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func section(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(note).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Day by day

    /// The day under the pointer, if it had a set.
    private var hovered: Training.Day? {
        hoveredDay.flatMap { hovered in training.days.first { training.calendar.isDate($0.day, inSameDayAs: hovered) } }
    }

    private var volumeChart: some View {
        Chart {
            ForEach(training.days, id: \.day) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Push-ups", day.reps), width: .ratio(0.6))
                    .foregroundStyle(Color.seriesOne)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .opacity(hovered == nil || hovered?.day == day.day ? 1 : 0.35)
            }
            if let day = hovered {
                pointer(at: day.day).annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    tooltip("\(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))", [
                        (nil, "^[\(day.reps) push-up](inflect: true) in ^[\(day.sets) set](inflect: true)"),
                    ])
                }
            }
        }
        .modifier(DayAxes(span: training.span))
        .chartXSelection(value: $hoveredDay)
        .frame(height: 200)
    }

    private var formByDay: some View {
        Chart {
            ForEach(training.days, id: \.day) { day in
                formLines(.value("Day", day.day, unit: .day), full: day.weekFull, straight: day.weekStraight)
            }
            if let day = hovered {
                pointer(at: day.day).annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    tooltip("\(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))", [
                        (.seriesOne, "\(percent(day.weekFull)) full range"),
                        (.seriesTwo, "\(percent(day.weekStraight)) straight back"),
                    ])
                }
            }
        }
        .modifier(FormAxes())
        .modifier(DayAxes(span: training.span))
        .chartXSelection(value: $hoveredDay)
        .frame(height: 180)
    }

    private var timeByDay: some View {
        Chart {
            ForEach(training.days, id: \.day) { day in
                LineMark(x: .value("Day", day.day, unit: .day), y: .value("Seconds", day.weekSeconds))
                    .trend(.seriesOne)
            }
            if let day = hovered {
                pointer(at: day.day).annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    tooltip("\(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))", [(nil, "\(seconds(day.weekSeconds))")])
                }
            }
        }
        .modifier(DayAxes(span: training.span))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { AxisMarks { _ in AxisGridLine(stroke: .hairline); AxisValueLabel() } }
        .chartXSelection(value: $hoveredDay)
        .frame(height: 180)
    }

    // MARK: Within a set

    /// The rep number under the pointer, if it's charted.
    private var hoveredPlace: Training.Place? {
        hoveredRep.flatMap { hovered in training.places.first { $0.number == hovered } }
    }

    private var repDomain: ClosedRange<Int> { 1...max(training.places.count, 2) }

    private var formByPlace: some View {
        Chart {
            ForEach(training.places, id: \.number) { place in
                formLines(.value("Rep", place.number), full: place.full, straight: place.straight)
            }
            if let place = hoveredPlace {
                pointer(at: place.number).annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    tooltip("Rep \(place.number), in ^[\(place.sets) set](inflect: true)", [
                        (.seriesOne, "\(percent(place.full)) full range"),
                        (.seriesTwo, "\(percent(place.straight)) straight back"),
                    ])
                }
            }
        }
        .modifier(FormAxes())
        .modifier(RepAxes(domain: repDomain))
        .chartXSelection(value: $hoveredRep)
        .frame(height: 180)
    }

    private var timeByPlace: some View {
        Chart {
            ForEach(training.places, id: \.number) { place in
                LineMark(x: .value("Rep", place.number), y: .value("Seconds", place.seconds))
                    .trend(.seriesOne)
            }
            if let place = hoveredPlace {
                pointer(at: place.number).annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    tooltip("Rep \(place.number), in ^[\(place.sets) set](inflect: true)", [(nil, "\(seconds(place.seconds))")])
                }
            }
        }
        .modifier(RepAxes(domain: repDomain))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { AxisMarks { _ in AxisGridLine(stroke: .hairline); AxisValueLabel() } }
        .chartXSelection(value: $hoveredRep)
        .frame(height: 180)
    }

    // MARK: Marks

    /// Full range and straight back at `x`, each a point on its own line.
    @ChartContentBuilder
    private func formLines<X: Plottable>(_ x: PlottableValue<X>, full: Double, straight: Double) -> some ChartContent {
        LineMark(x: x, y: .value("%", 100 * full), series: .value("Grade", "Full range"))
            .trend(.seriesOne)
        LineMark(x: x, y: .value("%", 100 * straight), series: .value("Grade", "Straight back"))
            .trend(.seriesTwo)
    }

    /// The line under the pointer, in a day's or a rep's column.
    private func pointer(at day: Date) -> some ChartContent {
        RuleMark(x: .value("Day", day, unit: .day)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(.hairline)
    }

    private func pointer(at rep: Int) -> some ChartContent {
        RuleMark(x: .value("Rep", rep)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(.hairline)
    }

    /// What's under the pointer: a title, and a line a value, each beside its series' colour if the chart has two.
    private func tooltip(_ title: LocalizedStringKey, _ lines: [(color: Color?, text: LocalizedStringKey)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    if let color = line.color { Circle().fill(color).frame(width: 8, height: 8) }
                    Text(line.text).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "78%"; a dash without a value.
private func percent(_ share: Double?) -> String {
    share.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
}

/// "0.96 s", with the reader's decimal separator.
private func seconds(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2))) + " s"
}

extension StrokeStyle {
    /// Gridlines and the pointer: a solid hairline.
    fileprivate static let hairline = StrokeStyle(lineWidth: 0.5)
}

extension LineMark {
    /// A trend line: 2 pt, rounded, eased between points without overshooting them.
    fileprivate func trend(_ color: Color) -> some ChartContent {
        foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
    }
}

/// A day-by-day chart's span and its weeks along the bottom.
private struct DayAxes: ViewModifier {
    let span: ClosedRange<Date>

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: span)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisGridLine(stroke: .hairline)
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
    }
}

/// A within-a-set chart's rep numbers along the bottom.
private struct RepAxes: ViewModifier {
    let domain: ClosedRange<Int>

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: domain)
            .chartXAxis { AxisMarks { _ in AxisGridLine(stroke: .hairline); AxisValueLabel() } }
    }
}

/// A form chart: 0–100 %, and its two lines named above it.
private struct FormAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(stroke: .hairline)
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            .chartForegroundStyleScale(["Full range": Color.seriesOne, "Straight back": Color.seriesTwo])
            .chartLegend(position: .top, alignment: .leading)
    }
}

extension Color {
    /// The dashboard's two series: the first two slots of the categorical palette in the dataviz guidelines, each
    /// stepped for light and dark, and checked there for colour-blind separation and contrast on both.
    fileprivate static let seriesOne = appearance(light: 0x2a78d6, dark: 0x3987e5)
    fileprivate static let seriesTwo = appearance(light: 0xeb6834, dark: 0xd95926)

    private static func appearance(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}
