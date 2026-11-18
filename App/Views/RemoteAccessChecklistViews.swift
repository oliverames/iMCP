import SwiftUI

extension RemoteChoice {
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
/// The Setup Assistant and the Remote Access tab in Settings both show it.
struct TailscaleChecklistView: View {
    let inputs: TailscaleChecklist.Inputs
    /// Opens a page that Tailscale asked the person to visit, and re-checks until the permission shows up.
    let openTailscalePage: (URL) -> Void
    let getSignInLink: () -> Void
    var compact = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(TailscaleChecklist.items(inputs)) { item in
                ChecklistRow(
                    title: ChecklistTitles.title(for: item.kind),
                    item: item,
                    openLink: { url in
                        if item.kind == .signedIn { openURL(url) } else { openTailscalePage(url) }
                    }
                )
            }
            if case .needsLogin(nil) = inputs.node {
                Button("Get Sign-In Link", action: getSignInLink)
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
