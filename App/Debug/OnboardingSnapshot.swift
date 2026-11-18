#if DEBUG
    import AppKit
    import Sparkle
    import SwiftUI

    /// Renders each step of the Setup Assistant to a PNG in light and dark, then exits.
    ///
    /// Run the app with `--snapshot-onboarding=<existing directory>`, and `--snapshot-dark` for dark mode.
    /// It draws the real windows in this process, so it needs neither
    /// Screen Recording nor Accessibility permission.
    @MainActor
    enum OnboardingSnapshot {
        static func runIfRequested(
            serverController: ServerController,
            isEnabled: Binding<Bool>,
            updater: SPUUpdater
        ) -> Bool {
            let prefix = "--snapshot-onboarding="
            guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
            else { return false }
            let directory = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)))

            Task { @MainActor in
                let suffix = ProcessInfo.processInfo.arguments.contains("--snapshot-min") ? "-min" : ""
                let only = ProcessInfo.processInfo.arguments.contains("--snapshot-dark")
                for appearance in only ? [NSAppearance.Name.darkAqua] : [.aqua] {
                    let name = appearance == .aqua ? "light" : "dark"
                    let menu = ContentView(serverManager: serverController, isEnabled: isEnabled, updater: updater)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let menuHost = NSHostingView(rootView: menu)
                    let menuWindow = NSWindow(
                        contentRect: NSRect(origin: .zero, size: NSSize(width: MenuMetrics.width, height: 1000)),
                        styleMask: [.borderless],
                        backing: .buffered,
                        defer: false
                    )
                    menuWindow.contentView = menuHost
                    menuWindow.appearance = NSAppearance(named: appearance)
                    menuWindow.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    let size = menuHost.fittingSize
                    menuWindow.setContentSize(NSSize(width: MenuMetrics.width, height: size.height))
                    try? await Task.sleep(for: .seconds(0.5))
                    if let rep = menuHost.bitmapImageRepForCachingDisplay(in: menuHost.bounds) {
                        menuHost.cacheDisplay(in: menuHost.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: directory.appending(path: "menu-\(name).png"))
                    }
                    menuWindow.orderOut(nil)
                    for step in OnboardingWizardView.Step.allCases {
                        let view = OnboardingWizardView(
                            serverController: serverController,
                            isEnabled: isEnabled,
                            initialStep: step,
                            onFinish: {}
                        )
                        let window = OnboardingWindowController.makeWindow(rootView: AnyView(view))
                        window.appearance = NSAppearance(named: appearance)
                        if ProcessInfo.processInfo.arguments.contains("--snapshot-min") {
                            window.setContentSize(window.contentMinSize)
                        }
                        window.center()
                        window.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(for: .seconds(1.5))
                        if let frame = window.contentView?.superview,
                            let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
                        {
                            frame.cacheDisplay(in: frame.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(
                                    to: directory.appending(
                                        path: "onboarding-step\(step.rawValue + 1)-\(name)\(suffix).png"
                                    )
                                )
                        }
                        window.orderOut(nil)
                    }
                }
                exit(0)
            }
            return true
        }
    }
#endif
