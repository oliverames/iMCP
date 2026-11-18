import Sparkle
import SwiftUI

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
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

    var body: some Scene {
        @Bindable var appDelegate = appDelegate

        // The binding lets removal hide the item without terminating the server.
        MenuBarExtra(
            isInserted: $appDelegate.isMenuBarExtraInserted
        ) {
            ContentView(
                serverManager: serverController,
                isEnabled: $isEnabled,
                updater: updaterController.updater
            )
        } label: {
            HStack(spacing: 3) {
                Image(#"MenuIcon-\#(isEnabled ? "On" : "Off")"#)
                #if DEBUG
                    Text("DEV")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                #endif
            }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: showMenuBarExtra) { _, showMenuBarExtra in
            appDelegate.isMenuBarExtraInserted = showMenuBarExtra
        }
        .onChange(of: appDelegate.shouldOpenSettings, initial: true) { _, shouldOpenSettings in
            guard shouldOpenSettings else { return }
            appDelegate.shouldOpenSettings = false
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .onChange(of: appDelegate.shouldCheckOnboarding, initial: true) { _, shouldCheck in
            guard shouldCheck else { return }
            appDelegate.shouldCheckOnboarding = false
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

        Settings {
            SettingsView(
                serverController: serverController,
                isMenuBarExtraInserted: appDelegate.isMenuBarExtraInserted
            )
        }

        .commands {
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
