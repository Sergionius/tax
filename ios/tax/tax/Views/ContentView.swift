import SwiftUI

struct ContentView: View {
    var body: some View {
        WorkspaceListView()
            // Тёмная схема приложения: светлый (белый) статус-бар на всех экранах,
            // включая терминальный. Видимых элементов терминала не меняет — у него
            // собственные явные цвета фона и панели.
            .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environment(SettingsStore())
        .environment(AppState())
        .environment(RemoteWorkspaceStore())
}
