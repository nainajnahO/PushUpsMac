import PushUpsEngine
import SwiftUI

@main
struct PushUpsMacApp: App {
    @State private var model = ClipModel()

    var body: some Scene {
        Window("PushUpsMac", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            SidebarCommands()
            // Nothing here prints.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .newItem) {
                Button("Open…", systemImage: "folder") { model.isImporting = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Toggle("Show Whole Skeleton", isOn: Binding { model.overlayStyle == .full } set: { model.overlayStyle = $0 ? .full : .near })
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}
