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
                PlayerView(player: player)
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
