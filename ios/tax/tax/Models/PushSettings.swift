import Foundation

enum PushMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case all
    case taxOnly = "tax"
    case off

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "Все"
        case .taxOnly: "Только tax"
        case .off: "Выключены"
        }
    }
}

struct DevicePreferences: Codable, Sendable {
    let pushMode: PushMode
    enum CodingKeys: String, CodingKey { case pushMode = "push_mode" }
}

struct DeviceTokenPayload: Codable, Sendable {
    let deviceToken: String
    let preferences: DevicePreferences
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token"; case preferences }
}

struct HealthResponse: Codable, Sendable { let ok: Bool }
