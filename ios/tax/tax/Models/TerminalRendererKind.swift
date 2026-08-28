import Foundation

enum TerminalRendererKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case swiftTerm = "swiftterm"
    case xterm = "xterm"

    var id: Self { self }

    var title: String {
        switch self {
        case .swiftTerm: "SwiftTerm"
        case .xterm: "xterm.js"
        }
    }
}
