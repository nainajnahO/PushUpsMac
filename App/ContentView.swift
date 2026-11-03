import AVKit
import PushUpsEngine
import SwiftUI

struct ContentView: View {
    @Environment(ClipModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ResultList()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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

/// The sidebar: the clip's result.
struct ResultList: View {
    @Environment(ClipModel.self) private var model

    var body: some View {
        List {
            if let analysis = model.analysis {
                Section("Result") {
                    LabeledContent("Push-ups", value: "\(analysis.count)")
                    if let summary = RepSummary(analysis.reps, metric: model.settings.metric) {
                        LabeledContent("Average push-up time", value: summary.meanSeconds.formatted(.number.precision(.fractionLength(2))) + " s")
                    }
                    let (full, straight, graded) = analysis.tally
                    LabeledContent("Full range", value: "\(full) of \(graded)")
                    LabeledContent("Straight back", value: "\(straight) of \(graded)")
                    LabeledContent("Measured on", value: "the \(analysis.side.rawValue) side")
                }
            }
        }
    }
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
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
