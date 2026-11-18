import Foundation

/// The commands in the menu bar menu that run an action.
enum MenuAction: String, CaseIterable, Equatable {
    case setUp
    case configureClaudeDesktop
    case configureClaudeCode
    case copyServerCommand
    case settings
    case checkForUpdates
    case about
    case quit

    var title: String {
        switch self {
        case .setUp: "Set Up iMCP…"
        case .configureClaudeDesktop: "Configure Claude Desktop…"
        case .configureClaudeCode: "Configure Claude Code…"
        case .copyServerCommand: "Copy Server Command"
        case .settings: "Settings…"
        case .checkForUpdates: "Check for Updates…"
        case .about: "About iMCP"
        case .quit: "Quit iMCP"
        }
    }
}

/// A service as a checkable menu item.
struct MenuServiceItem: Equatable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let isOn: Bool
}

/// A group of menu items. The menu draws a separator between groups.
enum MenuSection: Equatable {
    /// The "Enable MCP Server" switch, and status lines under it.
    case server(isOn: Bool, status: [String])
    /// The services, in a submenu.
    case services(items: [MenuServiceItem], isEnabled: Bool)
    case actions([MenuAction])
}

/// What the menu bar menu contains, built from the app's state so that tests can check it.
///
/// The menu is a native menu, so SwiftUI and AppKit own the spacing, highlight,
/// keyboard navigation, and VoiceOver. This only decides which items appear, and in which groups.
enum MenuStructure {
    static func make(
        isServerEnabled: Bool,
        services: [MenuServiceItem],
        status: [String]
    ) -> [MenuSection] {
        return [
            .server(isOn: isServerEnabled, status: isServerEnabled ? status : []),
            .services(items: services, isEnabled: isServerEnabled),
            .actions([.setUp, .configureClaudeDesktop, .configureClaudeCode, .copyServerCommand]),
            .actions([.settings, .checkForUpdates, .about]),
            .actions([.quit]),
        ]
    }
}
