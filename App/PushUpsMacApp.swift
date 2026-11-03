import SwiftUI

@main
struct PushUpsMacApp: App {
    var body: some Scene {
        Window("PushUpsMac", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            // Nothing here prints.
            CommandGroup(replacing: .printItem) {}
        }
    }
}
