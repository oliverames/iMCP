import AppKit
import Foundation
import SwiftUI

/// Whether the setup wizard should open on its own at launch.
///
/// It opens automatically only at the first launch.
/// Once a person has seen it, by finishing, by choosing Finish Later,
/// or by closing its window,
/// it never opens on its own again. "Set Up iMCP…" in the menu or Settings still opens it.
enum OnboardingGate {
    static let seenDefaultsKey = "hasSeenOnboarding"

    static func shouldOpenAutomatically(
        hasSeenOnboarding: Bool,
        hasTrustedClient: Bool,
        hasConnectedBefore: Bool,
        hasServiceOnBeyondDefaults: Bool
    ) -> Bool {
        !hasSeenOnboarding && !hasTrustedClient && !hasConnectedBefore && !hasServiceOnBeyondDefaults
    }
}

/// Shows the setup wizard's window, and brings it to the front if it is already open.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var hostingController: NSHostingController<AnyView>?
    private var onSeen: (() -> Void)?

    convenience init() {
        self.init(window: nil)
    }

    /// Opens the setup wizard for `serverController` and `isEnabled`.
    func present(serverController: ServerController, isEnabled: Binding<Bool>) {
        let markSeen = {
            UserDefaults.standard.set(true, forKey: OnboardingGate.seenDefaultsKey)
        }
        var initialStep = OnboardingWizardView.Step.services
        #if DEBUG
            // `--onboarding-step=N` opens step N (0 to 4), for screenshots.
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--onboarding-step=") }),
                let value = Int(argument.dropFirst("--onboarding-step=".count)),
                let step = OnboardingWizardView.Step(rawValue: value)
            {
                initialStep = step
            }
        #endif
        let view = OnboardingWizardView(
            serverController: serverController,
            isEnabled: isEnabled,
            initialStep: initialStep,
            onFinish: { [weak self] in
                markSeen()
                self?.close()
            }
        )
        show(view, onSeen: markSeen)
    }

    /// Shows `content` in the window, and calls `onSeen` once when the window closes.
    func show(_ content: some View, onSeen: @escaping () -> Void) {
        self.onSeen = onSeen
        let rootView = AnyView(content)

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let controller = NSHostingController(rootView: rootView)
            self.hostingController = controller

            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onSeen?()
        onSeen = nil
    }
}
