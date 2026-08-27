import SwiftUI

struct ContentView: View {
    var body: some View {
        WorkspaceListView()
            .preferredColorScheme(.light)
    }
}

#Preview {
    ContentView()
        .environment(SettingsStore())
        .environment(AppState())
        .environment(RemoteWorkspaceStore())
}
