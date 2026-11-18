import AppKit
import Sparkle
import SwiftUI

/// The menu bar menu.
///
/// It is a native menu (`.menuBarExtraStyle(.menu)`), so the system owns the spacing,
/// hover highlight, keyboard navigation, and VoiceOver. The items come from ``MenuStructure``.
struct ContentView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    @Environment(\.openSettings) private var openSettings

    private let updater: SPUUpdater

    private static let aboutCredits: NSAttributedString = {
        let credits = NSMutableAttributedString(
            string: "Report an Issue",
            attributes: [
                .link: URL(string: "https://github.com/mattt/iMCP/issues/new")!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ]
        )
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
        return credits
    }()

    init(
        serverManager: ServerController,
        isEnabled: Binding<Bool>,
        updater: SPUUpdater
    ) {
        self.serverController = serverManager
        self._isEnabled = isEnabled
        self.updater = updater
    }

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    private var sections: [MenuSection] {
        MenuStructure.make(
            isServerEnabled: isEnabled,
            services: serviceConfigs.map {
                MenuServiceItem(
                    id: $0.id,
                    name: $0.name,
                    symbol: $0.iconName,
                    isOn: $0.binding.wrappedValue
                )
            },
            status: statusLines
        )
    }

    /// Informational lines under the server switch.
    private var statusLines: [String] {
        let providers = serverController.activePublicURLs.map(\.provider)
        guard !providers.isEmpty else { return [] }
        return ["Remote access: \(providers.joined(separator: ", "))"]
    }

    var body: some View {
        let sections = sections
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            view(for: section)
        }
    }

    @ViewBuilder
    private func view(for section: MenuSection) -> some View {
        switch section {
        case .server(_, let status):
            Toggle("Enable MCP Server", isOn: $isEnabled)
            ForEach(status, id: \.self) { line in
                Text(line)
            }
        case .services(let items, let isServerEnabled):
            Menu("Services") {
                ForEach(items) { item in
                    Toggle(isOn: serviceBinding(for: item.id)) {
                        Label(item.name, systemImage: item.symbol)
                    }
                }
            }
            .disabled(!isServerEnabled)
        case .actions(let actions):
            ForEach(actions, id: \.self) { action in
                button(for: action)
            }
        }
    }

    @ViewBuilder
    private func button(for action: MenuAction) -> some View {
        switch action {
        case .settings:
            Button(action.title) { run(action) }
                .keyboardShortcut(",", modifiers: .command)
        case .quit:
            Button(action.title) { run(action) }
                .keyboardShortcut("q", modifiers: .command)
        case .checkForUpdates:
            Button(action.title) { run(action) }
                .disabled(!updater.canCheckForUpdates)
        default:
            Button(action.title) { run(action) }
        }
    }

    private func serviceBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { serviceConfigs.first { $0.id == id }?.binding.wrappedValue ?? false },
            set: { newValue in
                guard let config = serviceConfigs.first(where: { $0.id == id }) else { return }
                serverController.setService(config, enabled: newValue)
            }
        )
    }

    private func run(_ action: MenuAction) {
        switch action {
        case .setUp:
            OnboardingWindowController.shared.present(
                serverController: serverController,
                isEnabled: $isEnabled
            )
        case .configureClaudeDesktop:
            ClaudeDesktop.showConfigurationPanel(serverController: serverController)
        case .configureClaudeCode:
            ClaudeCode.showConfigurationPanel(serverController: serverController)
        case .copyServerCommand:
            let command = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/imcp-server")
                .path
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
            _ = NSSound.play(.pop)
        case .settings:
            // openSettings() alone is unreliable for this accessory (LSUIElement) app.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        case .checkForUpdates:
            updater.checkForUpdates()
        case .about:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }
}
