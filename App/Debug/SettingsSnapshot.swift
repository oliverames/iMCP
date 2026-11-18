#if DEBUG
    import AppKit
    import Sparkle
    import SwiftUI

    /// Renders each Settings tab to a PNG at several window sizes, in light and dark, then exits.
    ///
    /// Run the app with `--snapshot-settings=<existing directory>`. Add `--settings-tab=<tab>` for one tab
    /// (a `SettingsTab` raw value, or `service-<id>` for one service's options) and `--settings-size=<width>x<height>`
    /// for one size. Without them it renders every tab at the default, minimum and a large size.
    /// It draws the real views in this process, so it needs neither Screen Recording nor Accessibility permission.
    @MainActor
    enum SettingsSnapshot {
        static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--snapshot-settings=") }
        }

        static func runIfRequested(serverController: ServerController, updater: SPUUpdater) -> Bool {
            let arguments = ProcessInfo.processInfo.arguments
            guard let argument = arguments.first(where: { $0.hasPrefix("--snapshot-settings=") }) else { return false }
            let directory = URL(fileURLWithPath: String(argument.dropFirst("--snapshot-settings=".count)))

            var tabs: [String] = SettingsTab.allCases.map(\.rawValue)
                + ["service-NotesService", "service-FilesService", "service-CalendarService", "service-HomeService"]
            if let tab = arguments.first(where: { $0.hasPrefix("--settings-tab=") }) {
                tabs = [String(tab.dropFirst("--settings-tab=".count))]
            }
            var sizes: [(String, NSSize)] = [
                ("default", SettingsWindowConfigurator.defaultSize),
                ("min", SettingsWindowConfigurator.minimumSize),
                ("large", NSSize(width: 1100, height: 800)),
            ]
            if let size = arguments.first(where: { $0.hasPrefix("--settings-size=") }) {
                let parts = String(size.dropFirst("--settings-size=".count)).split(separator: "x").compactMap {
                    Double($0)
                }
                if parts.count == 2 { sizes = [("custom", NSSize(width: parts[0], height: parts[1]))] }
            }

            Task { @MainActor in
                // Let the services and the remote access state settle.
                try? await Task.sleep(for: .seconds(2))
                for isDark in [false, true] {
                    for (sizeName, size) in sizes {
                        for tab in tabs {
                            await render(
                                tab: tab, size: size, sizeName: sizeName, isDark: isDark,
                                serverController: serverController, updater: updater, directory: directory
                            )
                        }
                    }
                }
                exit(0)
            }
            return true
        }

        private static func render(
            tab: String, size: NSSize, sizeName: String, isDark: Bool,
            serverController: ServerController, updater: SPUUpdater, directory: URL
        ) async {
            let root: AnyView
            if tab.hasPrefix("service-") {
                let id = String(tab.dropFirst("service-".count))
                guard let config = serverController.computedServiceConfigs.first(where: { $0.id == id }) else {
                    return
                }
                root = AnyView(
                    NavigationStack {
                        ServiceSettingsView(serverController: serverController, config: config)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
            } else {
                UserDefaults.standard.set(tab, forKey: "settingsPane")
                root = AnyView(
                    SettingsView(serverController: serverController, isMenuBarExtraInserted: true, updater: updater)
                )
            }
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView: root)
            window.setContentSize(size)
            window.backgroundColor = .windowBackgroundColor
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = "\(tab)-\(sizeName)-\(isDark ? "dark" : "light").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: name))
            }
            window.orderOut(nil)
        }
    }
#endif
