import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var statusMessage: String?
    @State private var isCheckingHealth = false
    @State private var isRegistering = false
    @State private var isSyncingPushMode = false
    @State private var showAPIKey = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Server") {
                TextField("Server URL", text: $settings.serverURL)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("settings.serverURL")
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
                            .accessibilityIdentifier("settings.apiKey")
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

            Section("Remote Mac") {
                TextField("Host ID", text: $settings.hostID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Device ID", text: $settings.remoteDeviceID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("256-bit encryption key", text: $settings.e2eeKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button("Paste Encryption Key") {
                    settings.e2eeKey = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    statusMessage = settings.e2eeKey.isEmpty ? "Pasteboard is empty." : "Encryption key pasted."
                }
            }

            Section("Terminal") {
                Picker("Renderer", selection: $settings.terminalRenderer) {
                    ForEach(TerminalRendererKind.allCases) { renderer in
                        Text(renderer.title).tag(renderer)
                    }
                }
                .accessibilityIdentifier("settings.terminalRenderer")
            }

            Section("Notifications") {
                Picker("Push notifications", selection: $settings.pushMode) {
                    ForEach(PushMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(isSyncingPushMode)

                if isSyncingPushMode {
                    HStack {
                        ProgressView()
                        Text("Syncing…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: settings.pushMode) { _, _ in
                syncPushMode()
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
                .accessibilityIdentifier("settings.save")

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

    private func syncPushMode() {
        settings.savePushMode()

        guard !settings.deviceToken.isEmpty else {
            statusMessage = "Push mode saved locally. Device token is not available yet."
            return
        }
        guard let service = settings.configuredService else {
            statusMessage = "Push mode saved locally. Configure API key and server URL to sync it."
            return
        }

        let token = settings.deviceToken
        let pushMode = settings.pushMode
        isSyncingPushMode = true
        Swift.Task {
            defer { isSyncingPushMode = false }
            do {
                try await service.registerDevice(token: token, pushMode: pushMode)
                statusMessage = "Push mode synced."
            } catch {
                statusMessage = "Push mode saved locally, but sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func registerSavedDeviceToken() {
        guard let service = settings.configuredService, !settings.deviceToken.isEmpty else { return }
        let token = settings.deviceToken
        let pushMode = settings.pushMode
        Swift.Task {
            do {
                try await service.registerDevice(token: token, pushMode: pushMode)
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
