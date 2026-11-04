import AVKit
import PushUpsEngine
import SwiftUI

struct ContentView: View {
    @Environment(ClipModel.self) private var model
    @Environment(Camera.self) private var camera
    @Environment(LiveModel.self) private var live

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } detail: {
            if camera.isOn {
                CameraView(camera: camera, live: live, style: model.overlayStyle, settings: model.settings)
            } else if let player = model.player {
                // The panel under the clip, the two sharing the window's height. A stack, not a
                // `VSplitView`: on macOS 27.2 the split view reports its current size as its minimum,
                // so the window could only ever grow.
                VStack(spacing: 0) {
                    PlayerView(player: player) {
                        if let analysis = model.analysis, let poses = model.poses {
                            PlayerOverlay(analysis: analysis, size: CGSize(width: poses.width, height: poses.height))
                                .environment(model)
                        }
                    }
                    .frame(minHeight: 200, maxHeight: .infinity)
                    if let analysis = model.analysis {
                        Divider()
                        // At least 340 pt, which keeps each chart's plot at about 77 pt.
                        PlayerPanel(analysis: analysis)
                            .frame(minHeight: 340, maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView("No Clip", systemImage: "figure.strengthtraining.functional",
                                       description: Text("Open a side-on clip of push-ups, or drop one here."))
            }
        }
        .navigationTitle(camera.isOn ? camera.currentName ?? "Camera" : model.url?.lastPathComponent ?? "PushUpsMac")
        .navigationSubtitle(camera.isOn ? camera.subtitle(posedPerSecond: live.posedPerSecond) : model.status)
        // A setting changed mid-set counts the set so far again with it, as on a clip.
        .onChange(of: model.settings) { _, settings in live.recount(with: settings) }
        .toolbar {
            ToolbarItemGroup {
                if camera.isOn, !camera.choices.isEmpty {
                    Picker("Camera", selection: Binding { camera.current ?? "" } set: { camera.select($0) }) {
                        ForEach(camera.choices) { Text($0.name).tag($0.id) }
                    }
                    .help("The camera to count from")
                }
                Toggle(isOn: Binding { camera.isOn } set: { on in
                    if on {
                        model.player?.pause()
                        Task { await camera.turnOn(feeding: live.start(settings: model.settings)) }
                    } else {
                        turnCameraOff()
                    }
                }) {
                    Label("Camera", systemImage: "camera")
                }
                .help("Count live from a camera: your iPhone, through Continuity Camera, or another camera")
                if !camera.isOn, model.isPosing {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .help("Finding the body in every frame")
                }
                Button("Open…", systemImage: "folder") { model.isImporting = true }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Only a movie: anything else would close the open clip for a file the app can't read.
            guard let url = urls.first,
                  (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .movie) == true
            else { return false }
            open(url, securityScoped: true)
            return true
        }
        // Clips sent by Finder's Open With and the Dock icon (the app's document types).
        .onOpenURL { url in open(url) }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url): open(url, securityScoped: true)
            case .failure(let error): model.importFailed(error)
            }
        }
    }

    /// A clip opened while the camera is on takes its place.
    private func open(_ url: URL, securityScoped: Bool = false) {
        turnCameraOff()
        model.open(url, securityScoped: securityScoped)
    }

    private func turnCameraOff() {
        camera.turnOff()
        live.stop()
    }
}

/// The camera's live picture with the overlay and the panel under it, or why there isn't one.
struct CameraView: View {
    let camera: Camera
    let live: LiveModel
    let style: OverlayStyle
    let settings: PushUpsEngine.Settings

    var body: some View {
        switch camera.status {
        case .off:
            EmptyView()
        case .starting:
            ProgressView("Starting the camera…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            ContentUnavailableView("No Access to the Camera", systemImage: "video.slash",
                                   description: Text("Turn on PushUpsMac in System Settings, under Privacy & Security, Camera."))
        case .noCamera:
            ContentUnavailableView("No Camera", systemImage: "video.slash",
                                   description: Text("Stand your iPhone near the Mac with Continuity Camera on, or connect a camera."))
        case .failed(let message):
            ContentUnavailableView("The Camera Stopped", systemImage: "exclamationmark.triangle", description: Text(message))
        case .running:
            if let capture = camera.capture {
                // As a clip's: the picture over the panel, sharing the window's height.
                VStack(spacing: 0) {
                    CameraPreview(session: capture.session, cameraID: camera.current)
                        .overlay { LiveOverlay(live: live, style: style) }
                        .frame(minHeight: 200, maxHeight: .infinity)
                    if let counter = live.shown {
                        Divider()
                        PanelView(counter: counter, settings: settings, playhead: nil)
                            .frame(minHeight: 340, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

/// The sidebar: the result and the reps, of the live set or the clip, and the settings that grade them.
struct Sidebar: View {
    @Environment(ClipModel.self) private var model
    @Environment(Camera.self) private var camera
    @Environment(LiveModel.self) private var live

    var body: some View {
        @Bindable var model = model
        @Bindable var live = live
        List {
            if camera.isOn {
                if let counter = live.shown {
                    ResultSections(analysis: counter, metric: model.settings.metric, jump: nil)
                }
            } else if let analysis = model.analysis {
                ResultSections(analysis: analysis, metric: model.settings.metric, jump: model.jump(to:))
            }
            Section("Spoken count") {
                Toggle("Say each rep's number", isOn: $live.speaksCount)
                    .help("Counting live, the Mac says each rep's number as it's counted.")
                Toggle("Add a cue for a short rep or a bent back", isOn: $live.speaksCues)
                    .disabled(!live.speaksCount)
                    .help("After the number, what fell short, as the rep list says it: \"not to the floor\", \"not back up\", \"hips low\", \"hips high\".")
            }
            Section {
                SettingSlider(title: "Down height", value: $model.settings.romDownHeight, range: 0.3...0.9, step: 0.05,
                              text: { $0.formatted(.number.precision(.fractionLength(2))) },
                              help: "How close the shoulder must come to the hand at the bottom, in arm lengths above the wrist, measured with the arm straight in your plank (about 1).")
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
                Button("Restore Defaults") { model.settings = Settings() }
                    .disabled(model.settings == Settings())
            } header: {
                Text("Settings")
            } footer: {
                Text("The defaults were set on six clips of one person, filmed side-on with the phone on the floor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The sidebar's result and reps. On a clip, a rep jumps the player to it.
struct ResultSections: View {
    let analysis: RepCounter
    let metric: Metric
    let jump: ((RepRow) -> Void)?

    var body: some View {
        Section("Result") {
            LabeledContent("Push-ups", value: "\(analysis.count)")
            if let summary = RepSummary(analysis.reps, metric: metric) {
                LabeledContent("Average push-up time", value: seconds(summary.meanSeconds))
            }
            let (full, straight, graded) = analysis.tally
            LabeledContent("Full range", value: "\(full) of \(graded)")
            LabeledContent("Straight back", value: "\(straight) of \(graded)")
            if let side = analysis.side {
                LabeledContent("Measured on", value: "the \(side.rawValue) side")
            }
        }
        if !analysis.reps.isEmpty {
            Section("Reps") {
                ForEach(analysis.reps.map { $0.row(metric: metric) }) { row in
                    if let jump {
                        Button { jump(row) } label: { RepRowView(row: row) }
                            .buttonStyle(.plain)
                            .help("Show rep \(row.id)")
                    } else {
                        RepRowView(row: row)
                    }
                }
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
            HStack(spacing: 12) {
                GradeLabel(text: row.range, ok: row.complete)
                GradeLabel(text: row.back, ok: row.straight)
            }
            .font(.caption)
        }
        .contentShape(.rect)
    }
}

/// One side of a rep's grade: a check or a cross as well as the colour, so it doesn't rest on colour alone.
struct GradeLabel: View {
    let text: String
    let ok: Bool

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
        }
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
/// through to the player's controls. Only this view and the panel's playhead lines read the playhead, so
/// only they redraw as it moves.
struct PlayerOverlay: View {
    @Environment(ClipModel.self) private var model
    let analysis: RepCounter
    /// The frame's size as shown.
    let size: CGSize

    var body: some View {
        GeometryReader { geometry in
            let rect = AVMakeRect(aspectRatio: size, insideRect: CGRect(origin: .zero, size: geometry.size))
            if let overlay = analysis.overlay(atFrame: model.playhead.frame, tolerance: model.settings.backToleranceDegrees) {
                OverlayView(frame: overlay, style: model.overlayStyle)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The panel under the clip: the whole set, with the model's playhead, as the overlay follows it.
struct PlayerPanel: View {
    @Environment(ClipModel.self) private var model
    let analysis: RepCounter

    var body: some View {
        PanelView(counter: analysis, settings: model.settings, playhead: model.playhead)
    }
}

/// AVKit's player view, with `overlay` between the video and the player's controls, so the controls
/// stay on top of it. AppKit's `AVPlayerView`, not SwiftUI's `VideoPlayer`: on macOS 27.2,
/// `VideoPlayer` crashes as it's first shown (in AVKit's own type metadata, before any of this code).
struct PlayerView<Overlay: View>: NSViewRepresentable {
    let player: AVPlayer
    @ViewBuilder let overlay: Overlay

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        // No Live Text or Visual Look Up on a paused frame: nothing to read in a workout, and its
        // overlay (VisionKit's, 354 pt high) broke the layout once the panel made the player shorter.
        view.allowsVideoFrameAnalysis = false
        view.player = player
        let host = PassThroughHostingView(rootView: overlay)
        if let content = view.contentOverlayView {
            host.frame = content.bounds
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
        }
        context.coordinator.host = host
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        context.coordinator.host?.rootView = overlay
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: PassThroughHostingView<Overlay>?
    }
}

/// A hosting view that clicks go through, to the player under it.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
