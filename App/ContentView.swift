import AVKit
import PushUpsEngine
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(ClipModel.self) private var model
    @Environment(Camera.self) private var camera
    @Environment(LiveModel.self) private var live
    @Environment(\.modelContext) private var history
    @State private var page = Page.workout
    /// Why recorded sets couldn't be added to the history.
    @State private var historyProblems: [String] = []
    /// Why the last set couldn't be kept in the history.
    @State private var historyFailure: String?

    /// The toolbar's switch: counting, or your sets over time.
    private enum Page {
        case workout, progress
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if page == .progress {
                ProgressPage(metric: model.settings.metric, problems: historyProblems)
            } else {
                workout
            }
        }
        .navigationTitle(page == .progress ? "Progress"
                         : camera.isOn ? camera.held?.name ?? "Camera" : model.url?.lastPathComponent ?? "PushUpsMac")
        .navigationSubtitle(page == .progress ? ""
                            : camera.isOn ? camera.subtitle(posedPerSecond: live.posedPerSecond) : model.status)
        // A setting changed mid-set counts the set so far again with it, as on a clip.
        .onChange(of: model.settings) { _, settings in live.recount(with: settings) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $page) {
                    Text("Workout").tag(Page.workout)
                    Text("Progress").tag(Page.progress)
                }
                .pickerStyle(.segmented)
                // A set is going: it ends with the camera.
                .disabled(camera.isOn)
                .help("Count push-ups, or see your sets over time")
            }
            ToolbarItemGroup {
                if page == .workout { workoutTools }
            }
        }
        // The sets deleted before this launch go for good, and the sets recorded before the history was kept come
        // in, the first time.
        .task {
            do {
                try history.deleteRemovedSets()
            } catch {
                historyProblems.append("The deleted sets couldn't be cleared: \(error.localizedDescription)")
            }
            historyProblems += await history.addRecordedSets()
        }
        .alert("Couldn't Keep the Set", isPresented: Binding { historyFailure != nil } set: { if !$0 { historyFailure = nil } }) {
        } message: {
            Text(historyFailure ?? "")
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

    /// Counting: the sidebar, and the camera's picture or the clip.
    private var workout: some View {
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
    }

    /// The camera and its picker, and opening a clip.
    @ViewBuilder
    private var workoutTools: some View {
        if camera.isOn, !camera.choices.isEmpty {
            Picker("Camera", selection: Binding { camera.held?.id ?? "" } set: { camera.select($0) }) {
                ForEach(camera.choices) { Text($0.name).tag($0.id) }
            }
            .help("The camera to count from")
        }
        Toggle(isOn: Binding { camera.isOn } set: { on in
            if on {
                model.player?.pause()
                let (poser, recorder) = live.start(settings: model.settings)
                Task { await camera.turnOn(feeding: poser, recording: recorder) }
            } else {
                turnCameraOff(openingTheSet: true)
            }
        }) {
            Label("Camera", systemImage: "camera")
                .symbolEffect(.pulse, isActive: isRecording)
        }
        .tint(isRecording ? .red : nil)
        // Not while the last set is being written.
        .disabled(live.isStopping)
        .help(!camera.isOn ? "Count live from a camera: your iPhone, through Continuity Camera, or another camera"
              : isRecording ? "Stop recording, and open the set as a clip" : "Stop counting")
        if !camera.isOn, model.isPosing {
            ProgressView(value: model.progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help("Finding the body in every frame")
        }
        Button("Open…", systemImage: "folder") { model.isImporting = true }
    }

    /// The camera's frames are going into the set's recording: the Camera button is red and pulses.
    private var isRecording: Bool { live.isRecording && camera.status == .running }

    /// A clip opened while the camera is on takes its place; the set is still recorded and kept, but not opened.
    private func open(_ url: URL, securityScoped: Bool = false) {
        page = .workout
        turnCameraOff(openingTheSet: false)
        model.open(url, securityScoped: securityScoped)
    }

    /// Ends the live set and keeps it in the history, and opens its recording as a clip once it's written.
    private func turnCameraOff(openingTheSet: Bool) {
        guard camera.isOn else { return }
        camera.turnOff()
        Task {
            guard let ended = await live.stop() else { return }
            do {
                try history.keep(ended)
            } catch {
                historyFailure = error.localizedDescription
            }
            if let url = ended.recording, openingTheSet { model.open(url) }
        }
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
        case .waiting:
            ContentUnavailableView("Waiting for \(camera.held?.name ?? "the Camera")", systemImage: "video.badge.ellipsis",
                                   description: Text("The set goes on once it's back. To count from another camera, pick it in the toolbar."))
        case .failed(let message):
            ContentUnavailableView("The Camera Stopped", systemImage: "exclamationmark.triangle", description: Text(message))
        case .running:
            if let capture = camera.capture {
                // As a clip's: the picture over the panel, sharing the window's height.
                VStack(spacing: 0) {
                    CameraPreview(session: capture.session, cameraID: camera.held?.id)
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

/// The sidebar: how a live set is counted, and the settings that grade it. The results are in the panel.
struct Sidebar: View {
    @Environment(ClipModel.self) private var model
    @Environment(Camera.self) private var camera
    @Environment(LiveModel.self) private var live

    var body: some View {
        @Bindable var model = model
        @Bindable var live = live
        List {
            Section("Live") {
                Toggle("Say each rep's number", isOn: $live.speaksCount)
                    .help("Counting live, the Mac says each rep's number as it's counted.")
                Toggle("Add a cue for a short rep or a bent back", isOn: $live.speaksCues)
                    .disabled(!live.speaksCount)
                    .help("After the number, what fell short, as the rep list says it: \"not to the floor\", \"not back up\", \"hips low\", \"hips high\".")
                Toggle("Record each set", isOn: $live.records)
                    .disabled(camera.isOn)
                    .help("Saves the camera's video, without sound, and its poses to Movies › PushUpsMac, and opens the set as a clip once the camera is off.")
                if let failure = live.recordingFailure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                SettingSlider(title: "Back tolerance", value: $model.settings.backToleranceDegrees, range: 5...30, step: 1,
                              text: { "±\(Int($0))°" },
                              help: "How far the body line may bend, hips low or high, from descent to lockout.")
                Picker("Push-up time", selection: $model.settings.metric) {
                    Text("Moving").tag(Metric.moving)
                    Text("Whole way up").tag(Metric.ascent)
                }
                .help("Moving: from leaving the bottom to lockout, leaving out a pause on the floor. Whole way up: from the deepest point, the pause included.")
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

/// A setting's slider, its name and value above it. The trackpad taps as the slider reaches each step.
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
                .sensoryFeedback(.alignment, trigger: value)
        }
        .help(help)
    }
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
