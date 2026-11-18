import AppKit
import SwiftUI

/// How AI apps reach this Mac: the selected way, and the live state of its checklist.
/// The Setup Assistant and the Remote Access tab in Settings share it.
@MainActor
final class RemoteAccessCoordinator: ObservableObject {
    let serverController: ServerController

    /// The way that is selected. Cloudflare can be selected before it is set up.
    @Published var selection: RemoteChoice
    /// The person opened a Tailscale page, and iMCP is re-checking until the permission shows up.
    @Published private(set) var isWaitingForTailscale = false
    private var tailscaleTask: Task<Void, Never>?

    init(serverController: ServerController) {
        self.serverController = serverController
        self.selection = .local
        selection = currentChoice
    }

    /// The choice that the app's current remote access switches amount to.
    var currentChoice: RemoteChoice {
        RemoteChoice.current(
            .init(
                tailscale: serverController.isRemoteAccessEnabled,
                funnel: serverController.isRemoteAccessFunnelEnabled,
                cloudflare: serverController.cloudflareTunnel.isEnabled
            )
        )
    }

    /// Selects the way that matches the app's current state.
    func syncSelection() {
        selection = currentChoice
    }

    /// Applies a choice with the app's existing remote access state.
    /// Cloudflare only becomes selected here; it needs a login and a hostname first.
    func choose(_ choice: RemoteChoice) {
        selection = choice
        let target = choice.switches
        if serverController.isRemoteAccessEnabled != target.tailscale {
            serverController.isRemoteAccessEnabled = target.tailscale
        }
        if serverController.isRemoteAccessFunnelEnabled != target.funnel {
            serverController.isRemoteAccessFunnelEnabled = target.funnel
        }
        // Picking another way to reach this Mac ends the tunnel. Picking Cloudflare starts nothing until it is set up.
        if !target.cloudflare, serverController.cloudflareTunnel.isEnabled {
            serverController.cloudflareTunnel.setEnabled(false)
        }
    }

    /// The live state of iMCP's Tailscale node, as the checklist reads it.
    var tailscaleInputs: TailscaleChecklist.Inputs {
        let node: TailscaleChecklist.Node
        var funnelAllowed: Bool?
        var publicAddress = TailscaleChecklist.PublicAddress.off
        switch serverController.remoteAccessState {
        case .needsLogin(let url): node = .needsLogin(url)
        case .starting: node = .starting
        case .needsApproval: node = .needsApproval
        case .failed(let reason): node = .failed(reason)
        case .running(let endpoint):
            node = .running(dnsName: endpoint.dnsName)
            funnelAllowed = endpoint.funnelCapabilityGranted
            switch endpoint.funnel {
            case .off: break
            case .active(let url): publicAddress = URL(string: url).map { .active($0) } ?? .off
            case .failed(let message): publicAddress = .failed(message)
            }
        default: node = .off
        }
        return TailscaleChecklist.Inputs(
            node: node,
            funnelAllowed: funnelAllowed,
            publicAddress: publicAddress,
            wantsPublicAddress: selection == .funnel,
            isWaitingForApproval: isWaitingForTailscale
        )
    }

    /// Opens a page that Tailscale asked the person to visit, then re-checks every few seconds
    /// and moves on by itself when the permission turns up.
    func openTailscalePage(_ url: URL) {
        NSWorkspace.shared.open(url)
        isWaitingForTailscale = true
        tailscaleTask?.cancel()
        tailscaleTask = Task { [weak self] in
            for _ in 0 ..< 100 {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                if TailscaleChecklist.items(self.tailscaleInputs).allSatisfy(\.isDone) { break }
                self.serverController.refreshRemoteMobileConfiguration()
            }
            self?.isWaitingForTailscale = false
        }
    }

    func stop() {
        tailscaleTask?.cancel()
        tailscaleTask = nil
    }
}

extension RemoteChoice {
    /// The name in menus and summaries.
    var settingsName: String {
        switch self {
        case .local: "Local only"
        case .tailscale: "Tailscale"
        case .funnel: "Tailscale public address"
        case .cloudflare: "Cloudflare Tunnel"
        }
    }

    /// One short line that says what the way is for.
    var settingsCaption: String {
        switch self {
        case .local: "Only on your own network. Nothing is exposed."
        case .tailscale: "Private, from your own devices anywhere."
        case .funnel: "A public address for cloud apps, through Tailscale."
        case .cloudflare: "A public address on your own domain."
        }
    }

    var settingsSymbol: String {
        switch self {
        case .local: "house"
        case .tailscale: "lock.shield"
        case .funnel: "network"
        case .cloudflare: "cloud"
        }
    }
}

// MARK: - Checklists

/// The Tailscale lines of the checklist, with the live state beside each.
struct TailscaleChecklistView: View {
    @ObservedObject var remote: RemoteAccessCoordinator
    var compact = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(TailscaleChecklist.items(remote.tailscaleInputs)) { item in
                ChecklistRow(
                    title: ChecklistTitles.title(for: item.kind),
                    item: item,
                    openLink: { url in
                        if item.kind == .signedIn { openURL(url) } else { remote.openTailscalePage(url) }
                    }
                )
            }
            if case .needsLogin(nil) = remote.tailscaleInputs.node {
                Button("Get Sign-In Link") { remote.serverController.restartRemoteAccessNode() }
                    .checklistButton(compact: compact)
            }
        }
    }
}

/// The Cloudflare lines of the checklist, with sign-in, domain and hostname where each is needed.
struct CloudflareChecklistView: View {
    @ObservedObject var cloudflare: CloudflareTunnelController
    var compact = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let inputs = CloudflareChecklist.Inputs(
            isSignedIn: cloudflare.account != nil,
            activeDomains: cloudflare.zones.map(\.name),
            selectedDomain: cloudflare.selectedZone?.name,
            hostnameInput: cloudflare.hostnameDraft,
            isBinaryAvailable: cloudflare.isBinaryAvailable
        )
        let items = CloudflareChecklist.items(inputs)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                ChecklistRow(title: ChecklistTitles.title(for: item.kind), item: item, openLink: { openURL($0) })
                if item.kind == .signIn, cloudflare.account == nil {
                    HStack {
                        Button("Sign In with Browser") {
                            Task { await cloudflare.logInWithBrowser() }
                        }
                        .checklistButton(compact: compact)
                        .disabled(!cloudflare.isBinaryAvailable || cloudflare.state == .loggingIn)
                        if cloudflare.detectedCertURL != nil {
                            Button("Use Account on This Mac") {
                                Task { await cloudflare.useDetectedCert() }
                            }
                            .checklistButton(compact: compact)
                        }
                    }
                    .padding(.leading, 28)
                }
                if item.kind == .domain, cloudflare.zones.count > 1 {
                    Picker("Domain", selection: $cloudflare.selectedZoneID) {
                        ForEach(cloudflare.zones) { zone in Text(zone.name).tag(zone.id) }
                    }
                    .padding(.leading, 28)
                }
                if item.kind == .hostname, cloudflare.account != nil {
                    TextField(
                        "Hostname",
                        text: $cloudflare.hostnameDraft,
                        prompt: Text("imcp.\(cloudflare.selectedZone?.name ?? "example.com")")
                    )
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 28)
                    .accessibilityIdentifier("onboarding.cloudflare.hostname")
                }
            }

            if let url = cloudflare.state.activeURL {
                Label("Connected at \(url)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            } else if case .failed(let reason) = cloudflare.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Button("Set Up Tunnel") {
                Task { await cloudflare.provisionAndConnect() }
            }
            .checklistButton(compact: compact)
            .disabled(!CloudflareChecklist.isReady(items) || cloudflare.state.activeURL != nil)
            .accessibilityIdentifier("onboarding.cloudflare.setUp")
        }
    }
}

extension View {
    /// A checklist button: the Setup Assistant's glass button, or a plain bordered one in Settings.
    @ViewBuilder
    func checklistButton(compact: Bool) -> some View {
        if compact {
            self.buttonStyle(.bordered).controlSize(.regular)
        } else {
            self.onboardingSecondary()
        }
    }
}

enum ChecklistTitles {
    static func title(for kind: ChecklistItem.Kind) -> String {
        switch kind {
        case .signedIn: "Signed in to Tailscale"
        case .online: "This Mac is on your Tailscale network"
        case .name: "This Mac has a name"
        case .funnelAllowed: "Public addresses are allowed"
        case .publicAddress: "Public address is on"
        case .cloudflareAccount: "A Cloudflare account"
        case .domain: "A domain managed by Cloudflare"
        case .signIn: "iMCP can use your account"
        case .hostname: "A name for iMCP on that domain"
        case .willCreate: "What iMCP creates"
        }
    }
}

/// One line of a checklist: a check, a spinner, or a button, with the reason beneath.
struct ChecklistRow: View {
    let title: String
    let item: ChecklistItem
    let openLink: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if case .needsAction(let link) = item.status, let link {
                    Button(buttonTitle) { openLink(link) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var buttonTitle: String {
        switch item.kind {
        case .cloudflareAccount: "Create a Cloudflare account"
        case .domain: "Add a domain to Cloudflare"
        default: "Open in Tailscale"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .needsAction:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}
