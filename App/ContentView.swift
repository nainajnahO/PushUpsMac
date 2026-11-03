import AVKit
import PushUpsEngine
import SwiftUI

struct ContentView: View {
    @Environment(ClipModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } detail: {
            if let player = model.player {
                VStack(spacing: 0) {
                    PlayerView(player: player)
                        .overlay {
                            if let analysis = model.analysis, let poses = model.poses {
                                PlayerOverlay(analysis: analysis, video: poses.video)
                            }
                        }
                    if let analysis = model.analysis, let poses = model.poses {
                        PlayerPanel(analysis: analysis, video: poses.video)
                    }
                }
            } else {
                ContentUnavailableView("No Clip", systemImage: "figure.strengthtraining.functional",
                                       description: Text("Open a side-on clip of push-ups, or drop one here."))
            }
        }
        .navigationTitle(model.url?.lastPathComponent ?? "PushUpsMac")
        .navigationSubtitle(model.status)
        .toolbar {
            ToolbarItemGroup {
                if model.isPosing {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .help("Finding the body in every frame")
                }
                Button("Open…", systemImage: "folder") { model.isImporting = true }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url, securityScoped: true)
            return true
        }
        // Clips sent by Finder's Open With and the Dock icon (the app's document types).
        .onOpenURL { url in model.open(url) }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url): model.open(url, securityScoped: true)
            case .failure(let error): model.importFailed(error)
            }
        }
    }
}

/// The sidebar: the clip's result, its reps, and the settings that grade them.
struct Sidebar: View {
    @Environment(ClipModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            if let analysis = model.analysis {
                Section("Result") {
                    LabeledContent("Push-ups", value: "\(analysis.count)")
                    if let summary = RepSummary(analysis.reps, metric: model.settings.metric) {
                        LabeledContent("Average push-up time", value: seconds(summary.meanSeconds))
                    }
                    let (full, straight, graded) = analysis.tally
                    LabeledContent("Full range", value: "\(full) of \(graded)")
                    LabeledContent("Straight back", value: "\(straight) of \(graded)")
                    LabeledContent("Measured on", value: "the \(analysis.side.rawValue) side")
                }
                if !analysis.reps.isEmpty {
                    Section("Reps") {
                        ForEach(analysis.reps.map { $0.row(metric: model.settings.metric) }) { row in
                            Button { model.jump(to: row) } label: { RepRowView(row: row) }
                                .buttonStyle(.plain)
                                .help("Show rep \(row.id)")
                        }
                    }
                }
            }
            Section {
                SettingSlider(title: "Down height", value: $model.settings.romDownHeight, range: 0.3...1.2, step: 0.05,
                              text: { $0.formatted(.number.precision(.fractionLength(2))) },
                              help: "How close the shoulder must come to the hand at the bottom, in arm lengths above the wrist.")
                SettingSlider(title: "Up", value: $model.settings.romUpFraction, range: 0.7...1, step: 0.01,
                              text: { $0.formatted(.percent.precision(.fractionLength(0))) },
                              help: "How far back up a rep must come at lockout, as a share of your plank height.")
                SettingSlider(title: "Back tolerance", value: $model.settings.backToleranceDegrees, range: 5...30, step: 1,
                              text: { "±\(Int($0))°" },
                              help: "How far the body line may bend, hips low or high, from descent to lockout.")
                Picker("Push-up time", selection: $model.settings.metric) {
                    Text("Moving").tag(Metric.moving)
                    Text("Whole way up").tag(Metric.ascent)
                }
                .help("Moving: from leaving the bottom to lockout, leaving out a pause on the floor. Whole way up: from the deepest point, the pause included.")
                Picker("Side", selection: $model.settings.side) {
                    Text("Automatic").tag(Side?.none)
                    Text("Left").tag(Side?.some(.left))
                    Text("Right").tag(Side?.some(.right))
                }
                .help("The side of the body to measure. Automatic picks the one the camera sees best.")
                Button("Restore Defaults") { model.settings = .app }
                    .disabled(model.settings == .app)
            } header: {
                Text("Settings")
            } footer: {
                Text("The defaults were calibrated on six clips of one person, filmed side-on with the phone on the floor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A rep in the sidebar: its push-up time, when it starts and its other times, and its grade.
struct RepRowView: View {
    let row: RepRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rep \(row.id)").fontWeight(.medium)
                Spacer()
                Text(seconds(row.pushUpSeconds)).monospacedDigit()
            }
            Text("at \(seconds(row.startSeconds)) · down \(seconds(row.downSeconds)) · pause \(seconds(row.pauseSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let range = row.range, let back = row.back {
                Text("\(Text(range).foregroundStyle(row.complete ? .green : .red)) · \(Text(back).foregroundStyle(row.straight ? .green : .red))")
                    .font(.caption)
            }
        }
        .contentShape(.rect)
    }
}

/// A setting's slider, its name and value above it.
struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: (Double) -> String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(text(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
        }
        .help(help)
    }
}

private func seconds(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2))) + " s"
}

/// The overlay on the playing clip, on the model's playhead, so it follows playback and scrubbing
/// alike. Drawn in the rectangle the video fills (aspect fit, as the player shows it), and clicks go
/// through to the player's controls. Only this view and the panel read the playhead, so only they
/// redraw as it moves.
struct PlayerOverlay: View {
    @Environment(ClipModel.self) private var model
    let analysis: RepAnalysis
    let video: Poses.Video

    var body: some View {
        GeometryReader { geometry in
            let rect = AVMakeRect(aspectRatio: CGSize(width: video.width, height: video.height),
                                  insideRect: CGRect(origin: .zero, size: geometry.size))
            if let overlay = analysis.overlay(atSourceFrame: model.playhead, tolerance: model.settings.backToleranceDegrees) {
                OverlayView(frame: overlay, style: model.overlayStyle)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The panel under the clip, on the model's playhead, as the overlay is. As wide as the window, and
/// as high as the export's panel is for its width (1080 × 472).
struct PlayerPanel: View {
    @Environment(ClipModel.self) private var model
    let analysis: RepAnalysis
    let video: Poses.Video

    var body: some View {
        PanelView(analysis: analysis, settings: model.settings, fps: video.fps, frames: video.nFrames,
                  playhead: model.playhead)
            .aspectRatio(1080 / 472, contentMode: .fit)
    }
}

/// AVKit's player view. AppKit's `AVPlayerView`, not SwiftUI's `VideoPlayer`: on macOS 27.2,
/// `VideoPlayer` crashes as it's first shown (in AVKit's own type metadata, before any of this code).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        // No Live Text or Visual Look Up on a paused frame: nothing to read in a workout, and its
        // overlay (VisionKit's, 354 pt high) broke the layout once the panel made the player shorter.
        view.allowsVideoFrameAnalysis = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
