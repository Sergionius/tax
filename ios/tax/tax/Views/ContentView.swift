import SwiftUI

struct ContentView: View {
    var body: some View {
        TaskListView()
            .preferredColorScheme(.light)
    }
}

#Preview {
    ContentView()
        .environment(SettingsStore())
        .environment(AppState())
}
