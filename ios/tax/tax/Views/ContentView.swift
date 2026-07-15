import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            TaskListView()
                .tabItem {
                    Label("Tasks", systemImage: "list.bullet")
                }
                .tag(AppTab.tasks)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(AppTab.settings)
        }
    }
}

#Preview {
    ContentView()
        .environment(SettingsStore())
        .environment(AppState())
}
