import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView("No Clip", systemImage: "figure.strengthtraining.functional",
                               description: Text("A side-on clip of push-ups opens here."))
            .navigationTitle("PushUpsMac")
    }
}
