import Sparkle
import SwiftUI

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var serverController = ServerController()
    @AppStorage("isEnabled") private var isEnabled = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    // `startingUpdater: true` makes this the sole owner of update checking
    // for the app's lifetime.
    // Without it (or without ever constructing an updater at all),
    // the SUFeedURL / SUPublicEDKey keys in Info.plist are inert
    // and installs never learn about newer releases,
    // no matter how long they run.
    // Fork only: updates are off because this identity must not follow the upstream feed.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        #if DEBUG
            // Live check of the private Notes tools; exits before any service starts.
            NotesPrivateSelfTest.runAndExitIfRequested()
        #endif
    }

    private func installMenuBar() {
        MenuBarController.shared.install(serverController: serverController, updater: updaterController.updater)
    }

    var body: some Scene {
        @Bindable var appDelegate = appDelegate

        // The menu bar item is `MenuBarController`'s status item, because a `MenuBarExtra` window has
        // corners that are rounder than a native menu's. This never-inserted scene only carries the
        // app-level handlers below.
        MenuBarExtra("iMCP", systemImage: "circle", isInserted: .constant(false)) {
            EmptyView()
        }
        .onChange(of: isEnabled, initial: true) { _, isEnabled in
            installMenuBar()
            MenuBarController.shared.updateIcon(isOn: isEnabled)
        }
        .onChange(of: isEnabled) { _, isEnabled in
            // The panel's content isn't alive while it is closed, and the Setup Assistant changes this too.
            Task { await serverController.setEnabled(isEnabled) }
        }
        .onChange(of: showMenuBarExtra) { _, showMenuBarExtra in
            appDelegate.isMenuBarExtraInserted = showMenuBarExtra
        }
        .onChange(of: appDelegate.isMenuBarExtraInserted, initial: true) { _, inserted in
            installMenuBar()
            MenuBarController.shared.setVisible(inserted)
        }
        .onChange(of: appDelegate.shouldOpenSettings, initial: true) { _, shouldOpenSettings in
            guard shouldOpenSettings else { return }
            appDelegate.shouldOpenSettings = false
            SettingsWindowController.shared.configure(
                serverController: serverController,
                appDelegate: appDelegate,
                updater: updaterController.updater
            )
            SettingsWindowController.shared.show()
        }
        .onChange(of: appDelegate.shouldCheckOnboarding, initial: true) { _, shouldCheck in
            guard shouldCheck else { return }
            appDelegate.shouldCheckOnboarding = false
            SettingsWindowController.shared.configure(
                serverController: serverController,
                appDelegate: appDelegate,
                updater: updaterController.updater
            )
            #if DEBUG
                if SettingsSnapshot.runIfRequested(
                    serverController: serverController,
                    updater: updaterController.updater
                ) {
                    return
                }
                if OnboardingSnapshot.runIfRequested(
                    serverController: serverController,
                    isEnabled: $isEnabled,
                    updater: updaterController.updater
                ) {
                    return
                }
            #endif
            let defaults = UserDefaults.standard
            let hasSeen = defaults.bool(forKey: OnboardingGate.seenDefaultsKey)
            let hasTrusted =
                !serverController.trustedClients.isEmpty || !serverController.oauthConnections.grants.isEmpty
            let hasConnected = !serverController.activePublicURLs.isEmpty
            let hasServiceBeyondDefaults = serverController.computedServiceConfigs.contains {
                $0.name != "Maps" && $0.name != "Utilities" && $0.binding.wrappedValue
            }
            if OnboardingGate.shouldOpenAutomatically(
                hasSeenOnboarding: hasSeen,
                hasTrustedClient: hasTrusted,
                hasConnectedBefore: hasConnected,
                hasServiceOnBeyondDefaults: hasServiceBeyondDefaults
            ) {
                OnboardingWindowController.shared.present(
                    serverController: serverController,
                    isEnabled: $isEnabled
                )
            }
        }

        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldOpenSettings = false
    var shouldCheckOnboarding = false
    // System removal must not overwrite the user's saved preference.
    var isMenuBarExtraInserted =
        UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        shouldCheckOnboarding = true
        DockPresence.shared.start()
        #if DEBUG
            // Live check of the private Reminders tools; see App/Debug/RemindersPrivateSelfTest.swift.
            if ProcessInfo.processInfo.arguments.contains("--reminders-private-selftest") {
                Task.detached {
                    let report = await RemindersPrivateSelfTest.run()
                    print("RPSELFTEST-BEGIN\n\(report)\nRPSELFTEST-END")
                    fflush(stdout)
                    exit(0)
                }
                return
            }
        #endif
        // An unset preference defaults to showing the menu bar item.
        if UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool == false {
            shouldOpenSettings = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Reopening the app must work even when the menu bar item is absent.
        shouldOpenSettings = true
        return false
    }
}

/// Shows iMCP in the Dock, with its menu bar, while a Settings, Setup Assistant or other titled window is open,
/// and goes back to the menu bar alone when the last one closes.
///
/// The menu bar panel and alerts are not titled windows, so they never put the app in the Dock.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var observers: [any NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                    MainActor.assumeIsolated { self?.update(excluding: closing) }
                }
            )
        }
    }

    /// Whether a window that people use is open. A minimized window still counts, so it stays reachable.
    private func hasAppWindow(excluding closing: NSWindow?) -> Bool {
        NSApp.windows.contains { window in
            window !== closing
                && window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    private func update(excluding closing: NSWindow?) {
        let wantsDock = hasAppWindow(excluding: closing)
        let current = NSApp.activationPolicy()
        if wantsDock, current != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else if !wantsDock, current != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
