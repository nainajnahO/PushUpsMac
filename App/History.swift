import CoreTransferable
import Foundation
import OSLog
import PushUpsEngine
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

nonisolated private let log = Logger(subsystem: "nainajnahO.PushUpsMac", category: "history")

/// A set in the history, kept once the camera is off: when it started, its reps as they were counted, and the
/// movies it was recorded in, by name in ``LiveModel/folder``. Sets merged into one keep every movie. A set
/// without reps isn't kept.
@Model
final class SavedSet {
    var start: Date
    var reps: [SavedRep]
    var recordings: [String]
    /// Deleted, or merged into another set, and kept only so Undo can bring it back: the next launch deletes it.
    var removed = false

    init(start: Date, reps: [SavedRep], recordings: [String]) {
        (self.start, self.reps, self.recordings) = (start, reps, recordings)
    }

    var past: PastSet { PastSet(start: start, reps: reps) }
}

// The history's edits (deleting a set, merging sets, removing a rep) happen at once, and Edit › Undo takes each
// back, with Redo after it: each edit registers its own undo with the window's undo manager. A deleted set is only
// marked removed until the next launch, so Undo finds it as it was, and its movie comes back out of the Trash.
// SwiftData's own undo can't be used: undoing a saved deletion brings the set back without its reps, and reading
// them crashes (macOS 27.2). Keeping a set and adding the recorded ones aren't edits, and have no undo.
extension ModelContext {
    /// Keeps a set that has ended, if it has reps.
    func keep(_ set: LiveModel.EndedSet) throws {
        guard !set.reps.isEmpty else { return }
        insert(SavedSet(start: set.start, reps: set.reps.map(SavedRep.init),
                        recordings: set.recording.map { [$0.lastPathComponent] } ?? []))
        try save()
        log.notice("kept a set of \(set.reps.count) reps")
    }

    /// Deletes `sets` and moves their movies to the Trash. If a movie can't be moved, nothing is deleted, and the
    /// error says why.
    func remove(_ sets: [SavedSet], undo: UndoManager?) throws {
        var trashed: [(from: URL, to: URL)] = []
        do {
            for name in sets.flatMap(\.recordings) {
                let url = LiveModel.folder.appending(component: name)
                // Gone from the folder already: nothing to move.
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
                var inTrash: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &inTrash)
                if let inTrash = inTrash as URL? { trashed.append((url, inTrash)) }
            }
        } catch {
            putBack(trashed)
            throw error
        }
        for set in sets { set.removed = true }
        try save()
        log.notice("deleted \(sets.count) sets, \(trashed.count) movies to the Trash")
        register(undo, sets.count == 1 ? "Delete Set" : "Delete \(sets.count) Sets") { context in
            context.putBack(trashed)
            for set in sets { set.removed = false }
            context.saveForUndo()
            context.register(undo, nil) { try $0.remove(sets, undo: undo) }
        }
    }

    /// Joins `sets` into the earliest of them: from its start, with every set's reps at their times and every
    /// set's movies.
    func merge(_ sets: [SavedSet], undo: UndoManager?) throws {
        let sets = sets.sorted { $0.start < $1.start }
        guard sets.count > 1, let merged = PastSet.merged(sets.map(\.past)) else { return }
        let (first, others) = (sets[0], Array(sets.dropFirst()))
        let before = (reps: first.reps, recordings: first.recordings)
        first.reps = merged.reps
        first.recordings = sets.flatMap(\.recordings)
        for set in others { set.removed = true }
        try save()
        log.notice("merged \(sets.count) sets into one of \(merged.reps.count) reps")
        register(undo, "Merge Sets") { context in
            (first.reps, first.recordings) = before
            for set in others { set.removed = false }
            context.saveForUndo()
            context.register(undo, nil) { try $0.merge(sets, undo: undo) }
        }
    }

    /// Removes the reps at `places` from `set`. The movie keeps every rep.
    func remove(reps places: IndexSet, from set: SavedSet, undo: UndoManager?) throws {
        let name = places.count == 1 ? "Remove Rep" : "Remove \(places.count) Reps"
        let before = set.reps
        set.reps.remove(atOffsets: places)
        try save()
        log.notice("removed \(places.count) reps from a set")
        register(undo, name) { $0.replaceReps(of: set, with: before, undo: undo) }
    }

    /// Undo and Redo for ``remove(reps:from:undo:)``: `set`'s reps back as they were, and the other way registered.
    private func replaceReps(of set: SavedSet, with reps: [SavedRep], undo: UndoManager?) {
        let current = set.reps
        set.reps = reps
        saveForUndo()
        register(undo, nil) { $0.replaceReps(of: set, with: current, undo: undo) }
    }

    /// Registers `change` with `undo`, named `name` in the Edit menu; nil keeps the name an undo or redo already has.
    private func register(_ undo: UndoManager?, _ name: String?, _ change: @escaping (ModelContext) throws -> Void) {
        undo?.registerUndo(withTarget: self) { context in
            do {
                try change(context)
            } catch {
                // An undo has no one to tell but the log.
                log.error("couldn't undo or redo: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let name { undo?.setActionName(name) }
    }

    /// Movies moved to the Trash, back where they were. An undo has no one to tell of a failure but the log.
    private func putBack(_ movies: [(from: URL, to: URL)]) {
        for movie in movies {
            do {
                try FileManager.default.moveItem(at: movie.to, to: movie.from)
                log.notice("put \(movie.from.lastPathComponent, privacy: .public) back from the Trash")
            } catch {
                log.error("couldn't put \(movie.from.lastPathComponent, privacy: .public) back from the Trash: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func saveForUndo() {
        do {
            try save()
        } catch {
            log.error("couldn't save an undo or redo: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes for good the sets removed before this launch, whose undo went with it.
    func deleteRemovedSets() throws {
        try delete(model: SavedSet.self, where: #Predicate { $0.removed })
        try save()
    }

    /// Adds the sets recorded before the history was kept, the first time the app runs with it. Each movie in
    /// ``LiveModel/folder`` with poses and reps is counted from its poses with the default settings and dated by
    /// the file. Later it isn't looked at again, so a set deleted from the history stays deleted. Returns why
    /// each movie that couldn't be added wasn't.
    func addRecordedSets() async -> [String] {
        let key = "addedRecordedSets"
        guard !UserDefaults.standard.bool(forKey: key) else { return [] }
        let movies: [URL]
        do {
            movies = try FileManager.default.contentsOfDirectory(at: LiveModel.folder, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "mov" }
        } catch CocoaError.fileReadNoSuchFile {
            // Nothing recorded yet.
            movies = []
        } catch {
            log.error("couldn't list the recordings: \(error.localizedDescription, privacy: .public)")
            return ["Movies › PushUpsMac couldn't be read: \(error.localizedDescription)"]
        }
        var problems: [String] = [], found: [SavedSet] = []
        for url in movies {
            do {
                // A movie without poses isn't a live set, and a set without reps isn't kept.
                guard let reps = try await recordedReps(in: url), !reps.isEmpty else { continue }
                guard let start = try url.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                    problems.append("\(url.lastPathComponent) has no date")
                    continue
                }
                found.append(SavedSet(start: start, reps: reps, recordings: [url.lastPathComponent]))
                log.notice("added \(url.lastPathComponent, privacy: .public): \(reps.count) reps")
            } catch {
                problems.append("\(url.lastPathComponent) couldn't be read: \(error.localizedDescription)")
                log.error("couldn't add \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            for set in found { insert(set) }
            try save()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            problems.append("The recorded sets couldn't be saved: \(error.localizedDescription)")
        }
        return problems
    }
}

/// A recorded set's reps, counted from the poses in its movie with the default settings; nil for a movie
/// without poses. Off the main thread: a minute's poses take a moment to read.
@concurrent
nonisolated private func recordedReps(in url: URL) async throws -> [SavedRep]? {
    guard let poses = try await Poses.recorded(in: url) else { return nil }
    return RepCounter(poses: poses, settings: PushUpsEngine.Settings()).reps.map(SavedRep.init)
}

/// A set dragged in the list, to drop on another and merge the two: the app's own type, declared in Info.plist.
struct DraggedSet: Codable, Transferable {
    let id: PersistentIdentifier

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "nainajnahO.PushUpsMac.set"))
    }
}

/// What the list's top rows gather the sets by; each opens to the next shorter, down to days, which open to sets.
enum Grouping: String, CaseIterable, Identifiable {
    case day, week, month, year

    var id: Self { self }

    var name: LocalizedStringKey {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// The periods a row of this one opens to; nil for a day, which opens to its sets.
    var shorter: Grouping? {
        switch self {
        case .year: .month
        case .month: .week
        case .week: .day
        case .day: nil
        }
    }
}

/// A row of the list: a year, month, week or day, as much of it as lies in the row it's under, with its sets and
/// the shorter periods it opens to.
struct Period: Identifiable {
    let grouping: Grouping
    let interval: DateInterval
    /// Newest first.
    let sets: [SavedSet]
    /// Newest first; none for a day.
    let periods: [Period]
    /// Under another row: a week of a month is only that month's days of it.
    let isNested: Bool

    var id: String { "\(grouping.rawValue) \(interval.start.timeIntervalSinceReferenceDate)" }

    /// `sets` by `grouping`, newest first, each as much as lies `within` the row they're under.
    static func of(_ sets: [SavedSet], by grouping: Grouping, within: DateInterval? = nil) -> [Period] {
        let calendar = Calendar.current
        return Dictionary(grouping: sets) { set in
            let whole = calendar.dateInterval(of: grouping.component, for: set.start)!
            return within.flatMap { whole.intersection(with: $0) } ?? whole
        }
        .sorted { $0.key.start > $1.key.start }
        .map { interval, sets in
            let sets = sets.sorted { $0.start > $1.start }
            return Period(grouping: grouping, interval: interval, sets: sets,
                          periods: grouping.shorter.map { of(sets, by: $0, within: interval) } ?? [], isNested: within != nil)
        }
    }

    /// "Today", "Wed 4 Nov", "This week", "2–8 Nov", "November 2026", or under its year "November", "2026".
    var title: String {
        let calendar = Calendar.current, now = Date.now, start = interval.start
        let thisYear = calendar.isDate(start, equalTo: now, toGranularity: .year)
        switch grouping {
        case .day:
            if calendar.isDateInToday(start) { return String(localized: "Today") }
            if calendar.isDateInYesterday(start) { return String(localized: "Yesterday") }
            return start.formatted(thisYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                                   : .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        case .week:
            if !isNested, calendar.isDate(start, equalTo: now, toGranularity: .weekOfYear) { return String(localized: "This week") }
            if !isNested, calendar.isDate(start, equalTo: calendar.date(byAdding: .weekOfYear, value: -1, to: now)!,
                                          toGranularity: .weekOfYear) { return String(localized: "Last week") }
            // Its first day to its last, the end being the start of the day after.
            let days = start..<interval.end.addingTimeInterval(-1)
            return days.formatted(thisYear ? .interval.day().month(.abbreviated) : .interval.day().month(.abbreviated).year())
        case .month:
            return start.formatted(isNested ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
        case .year:
            return start.formatted(.dateTime.year())
        }
    }
}

/// The Progress tab: a row a year, month, week or day, newest first, with its totals, opening to the shorter
/// periods within it and a day to its sets, beside the dashboard over all of them, or one set's reps while it's
/// selected. Swipe a set left to delete it, drag it onto another to merge them, or use the context menu; Edit ›
/// Undo takes any of it back.
struct ProgressPage: View {
    @Environment(\.modelContext) private var history
    @Environment(\.undoManager) private var undo
    @Query(filter: #Predicate<SavedSet> { !$0.removed }, sort: \SavedSet.start, order: .reverse) private var sets: [SavedSet]
    @AppStorage("progressGrouping") private var grouping = Grouping.day
    @State private var selection = Set<SavedSet.ID>()
    /// The rows opened, by their periods' ids.
    @State private var opened = Set<Period.ID>()
    @State private var failure: String?
    /// The sidebar's Push-up time.
    let metric: Metric
    /// Why recorded sets couldn't be added.
    let problems: [String]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Period.of(sets, by: grouping)) { period in
                    PeriodNode(period: period, opened: $opened) { set in
                        SetRow(set: set) { dropped in
                            attempt { try history.merge([set] + sets.filter { dropped.contains($0.id) && $0.id != set.id }, undo: undo) }
                        } delete: {
                            attempt { try history.remove([set], undo: undo) }
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: SavedSet.ID.self) { ids in
                let chosen = sets.filter { ids.contains($0.id) }
                Button("Merge Sets") { attempt { try history.merge(chosen, undo: undo) } }
                    .disabled(chosen.count < 2)
                Button("Delete", role: .destructive) { attempt { try history.remove(chosen, undo: undo) } }
            }
            .onDeleteCommand { attempt { try history.remove(sets.filter { selection.contains($0.id) }, undo: undo) } }
            .safeAreaInset(edge: .top) {
                Picker("Group by", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .safeAreaInset(edge: .bottom) {
                if !problems.isEmpty {
                    Text(problems.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if selection.count == 1, let set = sets.first(where: { selection.contains($0.id) }) {
                SetDetail(set: set, metric: metric)
            } else {
                TrainingView(training: Training(sets.map(\.past), metric: metric))
            }
        }
        .alert("Couldn't Change the History", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
        } message: {
            Text(failure ?? "")
        }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            failure = error.localizedDescription
            log.error("couldn't change the history: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// A period's row, opening to the periods within it or, for a day, to its sets.
private struct PeriodNode: View {
    let period: Period
    @Binding var opened: Set<Period.ID>
    let setRow: (SavedSet) -> SetRow

    var body: some View {
        DisclosureGroup(isExpanded: Binding { opened.contains(period.id) } set: { open in
            if open { opened.insert(period.id) } else { opened.remove(period.id) }
        }) {
            if period.grouping == .day {
                ForEach(period.sets) { setRow($0) }
            } else {
                ForEach(period.periods) { PeriodNode(period: $0, opened: $opened, setRow: setRow) }
            }
        } label: {
            PeriodRow(title: period.title, sets: period.sets, isNested: period.isNested)
        }
    }
}

/// A day, week, month or year in the list: its push-ups, its sets, and how the reps went. A top row's title and
/// push-ups are heavier than those of the rows under it.
private struct PeriodRow: View {
    let title: String
    let sets: [SavedSet]
    let isNested: Bool

    var body: some View {
        let reps = sets.flatMap(\.reps)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(isNested ? .regular : .semibold)
                Spacer()
                Text("^[\(reps.count) push-up](inflect: true)").fontWeight(isNested ? .regular : .semibold)
            }
            Text("^[\(sets.count) set](inflect: true) · \(share(reps.count { $0.complete }, of: reps.count)) full range · \(share(reps.count { $0.backOK }, of: reps.count)) straight back")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func share(_ count: Int, of total: Int) -> String {
        (Double(count) / Double(max(total, 1))).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// A set in the list, under its day: when, its reps, and how they went.
private struct SetRow: View {
    let set: SavedSet
    /// Sets dropped on this one, to merge with it.
    let merge: ([PersistentIdentifier]) -> Void
    let delete: () -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(set.start, format: .dateTime.hour().minute())
                Spacer()
                Text("^[\(set.reps.count) push-up](inflect: true)").foregroundStyle(.secondary)
            }
            Text("\(set.reps.count { $0.complete }) full range · \(set.reps.count { $0.backOK }) straight back")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
            }
        }
        .draggable(DraggedSet(id: set.persistentModelID))
        .dropDestination(for: DraggedSet.self) { dropped, _ in
            merge(dropped.map(\.id))
            return true
        } isTargeted: { isTargeted = $0 }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // The trash can alone, as Mail shows it; "Delete" stays its name for VoiceOver.
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
        }
    }
}

/// One set's reps, to remove any counted by mistake. A set keeps at least one: to remove them all, delete it.
private struct SetDetail: View {
    @Environment(\.modelContext) private var history
    @Environment(\.undoManager) private var undo
    let set: SavedSet
    let metric: Metric
    @State private var selection = Set<Int>()
    @State private var failure: String?

    /// A rep and its place in the set, from 0.
    private struct Row: Identifiable {
        let id: Int
        let rep: SavedRep
    }

    var body: some View {
        Table(set.reps.enumerated().map { Row(id: $0.offset, rep: $0.element) }, selection: $selection) {
            TableColumn("Rep") { Text($0.id + 1, format: .number).monospacedDigit() }
            TableColumn("Push-up time") { Text("\($0.rep.seconds(metric), format: .number.precision(.fractionLength(2))) s").monospacedDigit() }
            TableColumn("Range") { Text($0.rep.reason.prefix(1).uppercased() + $0.rep.reason.dropFirst()) }
            TableColumn("Back") { Text($0.rep.backOK ? "Straight" : "Bent") }
        }
        .contextMenu(forSelectionType: Int.self) { places in
            Button(places.count == 1 ? "Remove Rep" : "Remove \(places.count) Reps") { remove(places) }
                .disabled(places.isEmpty || places.count == set.reps.count)
        }
        .onDeleteCommand { remove(selection) }
        .alert("Couldn't Change the History", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
        } message: {
            Text(failure ?? "")
        }
    }

    /// Removes the reps at `places`, unless that would leave none.
    private func remove(_ places: Set<Int>) {
        guard !places.isEmpty, places.count < set.reps.count else { return }
        selection = []
        do {
            try history.remove(reps: IndexSet(places), from: set, undo: undo)
        } catch {
            failure = error.localizedDescription
            log.error("couldn't remove reps: \(error.localizedDescription, privacy: .public)")
        }
    }
}
