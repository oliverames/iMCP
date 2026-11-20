import Foundation

// Where each setting lives, and which AI apps iMCP knows by name.
// Foundation-only, so the placement is unit tested without AppKit.

/// A pane in Settings, stored as its raw value so that Settings can reopen to it.
/// The four tabs sit above the Services section of the sidebar, which has a pane for each service.
enum SettingsPane: Hashable, RawRepresentable, Sendable {
    case general
    case clients
    case mobile
    case remoteAccess
    case advanced
    /// The pane for the service with this `ServiceConfig.id`.
    case service(String)

    /// The tabs, in the order the sidebar lists them.
    static let tabs: [SettingsPane] = [.general, .clients, .mobile, .remoteAccess, .advanced]

    init(rawValue: String) {
        switch rawValue {
        case "general": self = .general
        case "clients": self = .clients
        case "mobile": self = .mobile
        case "remoteAccess": self = .remoteAccess
        case "advanced": self = .advanced
        default: self = .service(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .general: "general"
        case .clients: "clients"
        case .mobile: "mobile"
        case .remoteAccess: "remoteAccess"
        case .advanced: "advanced"
        case .service(let id): id
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .clients: "Clients"
        case .mobile: "iPhone & iPad"
        case .remoteAccess: "Remote Access"
        case .advanced: "Advanced"
        case .service(let id): id
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .clients: "app.connected.to.app.below.fill"
        case .mobile: "ipad.and.iphone"
        case .remoteAccess: "network"
        case .advanced: "wrench.and.screwdriver"
        case .service: "square.grid.2x2"
        }
    }
}

/// Every control in the five tabs and the tab it lives in.
/// The list guards against a setting vanishing when a tab is rearranged.
/// The per-service panes are not listed: they are unchanged.
enum SettingsItem: CaseIterable, Sendable {
    // General
    case serverSwitch, menuBarIcon, launchAtLogin, approvalMode, setupAssistant, checkForUpdates
    // Clients
    case claudeDesktopSetup, claudeCodeSetup, connectorAddress, cloudClients, clientInstructions
    case trustedApps, approveAgainList, connectedCloudApps
    // iPhone & iPad
    case pairedDevices, pairDevice, unpairDevice, routeList, connectVia, approveOnIPhone, activityHistory
    // Remote Access
    case accessChoice, tailscaleChecklist, cloudflareChecklist, publicAddress, funnelPolicySnippet
    case tailscaleLogOut, cloudflareAccount
    // Advanced
    case serverCommand, accessTokens, tailscaleDeviceName, tailscalePort, tailscaleAddresses, tailscaleAuthKey
    case mobileOverrides, mobileDetails, cachedData

    var tab: SettingsPane {
        switch self {
        case .serverSwitch, .menuBarIcon, .launchAtLogin, .approvalMode, .setupAssistant, .checkForUpdates:
            .general
        case .claudeDesktopSetup, .claudeCodeSetup, .connectorAddress, .cloudClients, .clientInstructions,
            .trustedApps, .approveAgainList, .connectedCloudApps:
            .clients
        case .pairedDevices, .pairDevice, .unpairDevice, .routeList, .connectVia, .approveOnIPhone,
            .activityHistory:
            .mobile
        case .accessChoice, .tailscaleChecklist, .cloudflareChecklist, .publicAddress, .funnelPolicySnippet,
            .tailscaleLogOut, .cloudflareAccount:
            .remoteAccess
        case .serverCommand, .accessTokens, .tailscaleDeviceName, .tailscalePort, .tailscaleAddresses,
            .tailscaleAuthKey, .mobileOverrides, .mobileDetails, .cachedData:
            .advanced
        }
    }

    static func items(in tab: SettingsPane) -> [SettingsItem] {
        allCases.filter { $0.tab == tab }
    }
}

/// An AI app that iMCP shows with its own logo and steps.
struct KnownClient: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        /// Runs on this Mac, and iMCP can add itself to its settings.
        case onThisMac
        /// Connects over a public address.
        case cloud
    }

    let id: String
    let name: String
    let kind: Kind
    /// The asset catalog image, or nil for an app that uses a symbol.
    let logoAsset: String?
    let symbol: String
    /// Short steps for connecting.
    let steps: String
    /// Lowercased fragments that identify the app by the name it reports.
    let aliases: [String]

    static let claudeDesktop = KnownClient(
        id: "claudeDesktop",
        name: "Claude Desktop",
        kind: .onThisMac,
        logoAsset: "ConnectorClaude",
        symbol: "bubble.left.fill",
        steps: "Press Set Up. iMCP adds itself to Claude Desktop.",
        aliases: ["claude desktop"]
    )
    static let claudeCode = KnownClient(
        id: "claudeCode",
        name: "Claude Code",
        kind: .onThisMac,
        logoAsset: "ConnectorClaudeCode",
        symbol: "terminal",
        steps: "Press Set Up. iMCP adds itself to Claude Code.",
        aliases: ["claude code", "claude-code"]
    )
    static let claudeAI = KnownClient(
        id: "claudeAI",
        name: "Claude Web",
        kind: .cloud,
        logoAsset: "ConnectorClaude",
        symbol: "bubble.left.fill",
        steps:
            "In Claude Web (claude.ai), open Settings, then Connectors, then Add custom connector. Paste the address.",
        aliases: ["claude web", "claude.ai", "claude"]
    )
    static let claudeDuet = KnownClient(
        id: "claudeDuet",
        name: "Claude Duet",
        kind: .cloud,
        logoAsset: "ConnectorClaudeDuet",
        symbol: "bubble.left.and.bubble.right.fill",
        steps: "Add a custom connector in Claude Duet and paste the address. Approve once in iMCP.",
        aliases: ["duet"]
    )
    static let muse = KnownClient(
        id: "muse",
        name: "Muse",
        kind: .cloud,
        logoAsset: "ConnectorMuse",
        symbol: "sparkles",
        steps: "Add a connector in Muse and paste the address. Sign in when it asks.",
        aliases: ["muse"]
    )
    static let gemini = KnownClient(
        id: "gemini",
        name: "Gemini",
        kind: .cloud,
        logoAsset: "ConnectorGemini",
        symbol: "sparkle",
        steps: "Add a custom connector in Gemini and paste the address. Approve once in iMCP.",
        aliases: ["gemini"]
    )

    /// In the order Settings lists them.
    static let all: [KnownClient] = [.claudeDesktop, .claudeCode, .claudeAI, .claudeDuet, .muse, .gemini]

    /// The known app that a reported name belongs to, or nil for any other app.
    /// A specific app wins over the generic "Claude".
    static func match(name: String) -> KnownClient? {
        let lowered = name.lowercased()
        let order: [KnownClient] = [.claudeDuet, .muse, .gemini, .claudeCode, .claudeDesktop, .claudeAI]
        return order.first { client in client.aliases.contains { lowered.contains($0) } }
    }
}

extension MobileRouteKind {
    var settingsSymbol: String {
        switch self {
        case .local: "house"
        case .cloudflare: "cloud"
        case .tailscaleVPN: "lock.shield"
        case .tailscaleFunnel: "network"
        }
    }

    /// The name people know the route by.
    var settingsName: String {
        switch self {
        case .local: "Your network"
        case .cloudflare: "Cloudflare Tunnel"
        case .tailscaleVPN: "Tailscale"
        case .tailscaleFunnel: "Tailscale public address"
        }
    }
}
