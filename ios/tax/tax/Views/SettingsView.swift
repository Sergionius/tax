import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var statusMessage: String?
    @State private var isCheckingHealth = false
    @State private var isRegistering = false

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
                SecureField("API Key", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("API Key")
            } footer: {
                Text("Saved in Keychain. The backend requires Authorization: Bearer <API key>.")
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
            } footer: {
                Text("Copy this token to the Mac with: tax config --device-token <token>")
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
