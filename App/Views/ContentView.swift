import AppKit
import OSLog
import Sparkle
import SwiftUI

/// The menu bar panel.
///
/// It is a window-style `MenuBarExtra`, not an `NSMenu`, because a menu closes after every click
/// and the service rows must stay open while people turn several on or off.
/// Spacing follows a native menu: 22 pt rows, 4 pt around separators, and the system's
/// selected-menu-item colors for the hover highlight. The items come from ``MenuStructure``.
struct ContentView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    private let updater: SPUUpdater
    @State private var menuPanel = MenuPanelController()

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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { MenuSeparator() }
                view(for: section)
            }
        }
        .frame(width: MenuMetrics.width)
        .padding(.vertical, MenuMetrics.edge)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            menuPanel.contentWidth = size.width
            menuPanel.contentHeight = size.height
            menuPanel.resizeToFitContent()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MenuPanelWindowReader(controller: menuPanel))
    }

    @ViewBuilder
    private func view(for section: MenuSection) -> some View {
        switch section {
        case .server(_, let status):
            HStack {
                Text("Enable MCP Server")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Enable MCP Server", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .frame(minHeight: MenuMetrics.rowHeight)
            .padding(.horizontal, MenuMetrics.rowInset + MenuMetrics.edge)
            ForEach(status, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MenuMetrics.rowInset + MenuMetrics.edge)
                    .frame(minHeight: MenuMetrics.rowHeight, alignment: .leading)
            }
        case .services(let items):
            Text("Services")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, MenuMetrics.rowInset + MenuMetrics.edge)
                .frame(minHeight: MenuMetrics.rowHeight, alignment: .leading)
            servicesList(items)
        case .actions(let actions):
            ForEach(actions, id: \.self) { action in
                MenuRow(title: action.title, isDisabled: isDisabled(action)) {
                    run(action)
                }
            }
        }
    }

    /// The service rows. They scroll only when the screen is too short to show them all.
    @ViewBuilder
    private func servicesList(_ items: [MenuServiceItem]) -> some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                ServiceRow(
                    item: item,
                    config: serviceConfigs.first { $0.id == item.id },
                    serverController: serverController
                )
            }
        }
        let fullHeight = MenuMetrics.serviceRowHeight * CGFloat(items.count)
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 340
        if fullHeight > available {
            ScrollView { rows }
                .frame(height: max(available, MenuMetrics.serviceRowHeight * 4))
        } else {
            rows
        }
    }

    private func isDisabled(_ action: MenuAction) -> Bool {
        action == .checkForUpdates && !updater.canCheckForUpdates
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
        // Hiding the panel window directly leaves the status item presented,
        // so the next click on it does nothing.
        dismiss()
    }
}

/// The measurements of the panel, in points.
enum MenuMetrics {
    static let width: CGFloat = 260
    /// The gap between the panel's edge and its rows, as in a native menu.
    static let edge: CGFloat = 5
    /// Text starts this far inside a row's highlight.
    static let rowInset: CGFloat = 9
    static let rowHeight: CGFloat = 22
    static let iconSize: CGFloat = 22
    static let serviceRowHeight: CGFloat = 30
}

/// Resizes the `MenuBarExtra` panel that shows ``ContentView`` to fit its content.
@MainActor
final class MenuPanelController {
    private let log = Logger(subsystem: "com.amesconsulting.imcp.mac", category: "menu.panel")
    var contentWidth: CGFloat = 0
    var contentHeight: CGFloat = 0

    private weak var window: NSWindow?
    private var windowObserver: NSObjectProtocol?

    func attach(to newWindow: NSWindow?) {
        guard newWindow !== window else { return }

        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }

        window = newWindow
        guard let newWindow else { return }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resizeToFitContent()
            }
        }
        resizeToFitContent()
    }

    // MenuBarExtra's window keeps whatever size the system first gave it. When the content is narrower
    // or shorter, the content floats in an oversized panel, with wide margins on both sides.
    // Resize the window to the content, keeping it centered under the menu bar item and on screen.
    func resizeToFitContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.contentHeight > 0, self.contentWidth > 0 else {
                self?.log.notice(
                    "resize skipped: window \(self?.window != nil, privacy: .public) content \(self?.contentWidth ?? 0, privacy: .public)x\(self?.contentHeight ?? 0, privacy: .public)"
                )
                return
            }
            let frame = window.frame
            guard abs(frame.height - self.contentHeight) > 0.5 || abs(frame.width - self.contentWidth) > 0.5
            else {
                self.describe("already fits \(self.contentWidth)x\(self.contentHeight)", window)
                return
            }
            self.describe("before resize to \(self.contentWidth)x\(self.contentHeight)", window)
            var x = frame.midX - self.contentWidth / 2
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                x = min(max(x, visible.minX + 4), visible.maxX - self.contentWidth - 4)
            }
            window.setFrame(
                NSRect(
                    x: x,
                    y: frame.maxY - self.contentHeight,
                    width: self.contentWidth,
                    height: self.contentHeight
                ),
                display: true
            )
            self.describe("after resize", window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
                guard let self, let window else { return }
                self.describe("0.3s later", window)
            }
        }
    }

    private func describe(_ event: String, _ window: NSWindow) {
        let content = window.contentView
        log.notice(
            """
            \(event, privacy: .public): window \(NSStringFromRect(window.frame), privacy: .public), \
            contentView \(NSStringFromRect(content?.frame ?? .zero), privacy: .public), \
            contentLayoutRect \(NSStringFromRect(window.contentLayoutRect), privacy: .public), \
            safeArea \(String(describing: content?.safeAreaInsets), privacy: .public), \
            style \(window.styleMask.rawValue, privacy: .public), \
            class \(String(describing: type(of: window)), privacy: .public), \
            contentClass \(String(describing: content.map { type(of: $0) }), privacy: .public), \
            subviews \(content?.subviews.map { NSStringFromRect($0.frame) }.joined(separator: " | ") ?? "", privacy: .public)
            """
        )
    }
}

/// Gives ``MenuPanelController`` the window that contains this view.
private struct MenuPanelWindowReader: NSViewRepresentable {
    let controller: MenuPanelController

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(controller: controller)
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {}

    final class WindowReaderView: NSView {
        private let controller: MenuPanelController

        init(controller: MenuPanelController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.attach(to: window)
        }
    }
}

/// A separator with a 4 pt gap above and below and the standard inset.
private struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuMetrics.edge * 2)
            .padding(.vertical, 4)
    }
}

/// A command row. It's a real `Button`, so it works with the keyboard and VoiceOver,
/// and it highlights under the pointer like a menu item.
private struct MenuRow: View {
    let title: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
                .padding(.horizontal, MenuMetrics.rowInset)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .disabled(isDisabled)
        .padding(.horizontal, MenuMetrics.edge)
    }
}

/// A service as in Settings: its colored icon, then its name.
/// Clicking turns it on or off and leaves the panel open, so several can change in one visit.
private struct ServiceRow: View {
    let item: MenuServiceItem
    let config: ServiceConfig?
    @ObservedObject var serverController: ServerController

    var body: some View {
        Button {
            guard let config else { return }
            serverController.setService(config, enabled: !item.isOn)
        } label: {
            HStack(spacing: 8) {
                if let config {
                    ServiceIcon(config: config, isOn: item.isOn, size: MenuMetrics.iconSize)
                }
                Text(item.name)
                Spacer(minLength: 0)
            }
            .frame(minHeight: MenuMetrics.serviceRowHeight)
            .padding(.horizontal, MenuMetrics.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(.horizontal, MenuMetrics.edge)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .help("\(item.name) tools: \(toolSummary)")
    }

    private var toolSummary: String {
        config?.service.tools
            .map { $0.annotations.title ?? $0.name }
            .joined(separator: ", ") ?? ""
    }
}

/// The highlight of a menu item: the system's selected-menu-item colors under the pointer.
private struct MenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isEnabled && (isHovering || configuration.isPressed)
        configuration.label
            .foregroundStyle(
                isHighlighted
                    ? Color(nsColor: .selectedMenuItemTextColor)
                    : isEnabled ? Color.primary : Color(nsColor: .disabledControlTextColor)
            )
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHighlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
            )
            .onHover { isHovering = $0 }
    }
}
