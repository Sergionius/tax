import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var statusMessage: String?
    @State private var isCheckingHealth = false
    @State private var isRegistering = false
    @State private var showAPIKey = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Server") {
                TextField("Server URL", text: $settings.serverURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
            }

            Section {
                HStack {
                    if showAPIKey {
                        TextField("API Key", text: $settings.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $settings.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button(showAPIKey ? "Hide" : "Show") {
                        showAPIKey.toggle()
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button(settings.apiKey.isEmpty ? "Paste" : "Copy API Key") {
                        if settings.apiKey.isEmpty {
                            let pasted = UIPasteboard.general.string ?? ""
                            let normalized = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            settings.apiKey = normalized
                            statusMessage = normalized.isEmpty ? "Pasteboard is empty." : "API key pasted. length=\(normalized.count)"
                        } else {
                            UIPasteboard.general.string = settings.apiKey
                            statusMessage = "API key copied. length=\(settings.apiKey.count)"
                        }
                    }

                    Button("Clear", role: .destructive) {
                        settings.apiKey = ""
                        statusMessage = "API key cleared."
                    }
                    .disabled(settings.apiKey.isEmpty)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("Saved in Keychain when you tap Save Settings.")
            }

            Section {
                if settings.deviceToken.isEmpty {
                    ContentUnavailableView("Not registered yet", systemImage: "iphone.badge.exclamationmark")
                        .frame(maxWidth: .infinity)
                } else {
                    Text(settings.deviceToken)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Button("Copy Device Token") {
                    UIPasteboard.general.string = settings.deviceToken
                    statusMessage = "Device token copied."
                }
                .disabled(settings.deviceToken.isEmpty)

                Button(isRegistering ? "Requesting…" : "Request Push Registration") {
                    requestPushRegistration()
                }
                .disabled(isRegistering)
            } header: {
                Text("Device Token")
            }

            Section {
                Button("Save Settings") {
                    settings.save()
                    statusMessage = settings.lastSaveError ?? "Settings saved."
                    if !settings.deviceToken.isEmpty {
                        registerSavedDeviceToken()
                    }
                }

                Button(isCheckingHealth ? "Checking…" : "Check Server Health") {
                    Swift.Task { await checkHealth() }
                }
                .disabled(isCheckingHealth)
            }

            if let statusMessage {
                Section("Status") {
                    Text(statusMessage)
                        .foregroundStyle(settings.lastSaveError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func requestPushRegistration() {
        isRegistering = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            Swift.Task { @MainActor in
                isRegistering = false
                if let error {
                    statusMessage = error.localizedDescription
                } else if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                    statusMessage = "Push registration requested."
                } else {
                    statusMessage = "Push notifications are not authorized."
                }
            }
        }
    }

    private func registerSavedDeviceToken() {
        guard let service = settings.configuredService, !settings.deviceToken.isEmpty else { return }
        let token = settings.deviceToken
        Swift.Task {
            do {
                try await service.registerDevice(token: token)
                statusMessage = "Settings saved and device token registered."
            } catch {
                statusMessage = "Saved, but device registration failed: \(error.localizedDescription)"
            }
        }
    }

    private func checkHealth() async {
        guard let service = settings.configuredService else {
            statusMessage = "Configure API key and server URL first."
            return
        }

        isCheckingHealth = true
        defer { isCheckingHealth = false }

        do {
            statusMessage = try await service.health() ? "Server is healthy." : "Server health check failed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
