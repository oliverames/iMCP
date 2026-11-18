import AppKit
import SwiftUI

/// The Remote Access tab: how AI apps and your devices reach this Mac from outside.
/// It shares the Setup Assistant's choices and checklists.
struct RemoteAccessSettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject private var cloudflare: CloudflareTunnelController
    @StateObject private var remote: RemoteAccessCoordinator

    @State private var isShowingCredentialSheet = false
    @State private var isConfirmingTailscaleLogOut = false
    @State private var isConfirmingCloudflareLogOut = false

    init(serverController: ServerController) {
        self.serverController = serverController
        self.cloudflare = serverController.cloudflareTunnel
        _remote = StateObject(wrappedValue: RemoteAccessCoordinator(serverController: serverController))
    }

    var body: some View {
        let selection = remote.selection

        Form {
            Section {
                Picker(
                    selection: Binding(get: { remote.selection }, set: { remote.choose($0) })
                ) {
                    ForEach(RemoteChoice.allCases, id: \.self) { choice in
                        Label(choice.settingsName, systemImage: choice.settingsSymbol).tag(choice)
                    }
                } label: {
                    RowLabel(title: "Reach this Mac", subtitle: selection.settingsCaption) {
                        SettingsIcon(symbol: selection.settingsSymbol, color: .blue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                SectionTitle(title: "Access", symbol: "network")
            }

            switch selection {
            case .local:
                EmptyView()
            case .tailscale, .funnel:
                tailscaleSection(selection)
            case .cloudflare:
                cloudflareSection
            }

            if let url = serverController.activePublicURLs.first?.url {
                Section {
                    LabeledContent {
                        Button("Copy") { copyToSettingsPasteboard(url) }
                    } label: {
                        RowLabel(title: "Connector address", subtitle: url) {
                            SettingsIcon(symbol: "link", color: .teal)
                        }
                    }
                } header: {
                    SectionTitle(title: "Public address", symbol: "globe")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Remote Access")
        .onAppear {
            remote.syncSelection()
            cloudflare.refreshEnvironment()
        }
        .onDisappear { remote.stop() }
        .sheet(isPresented: $isShowingCredentialSheet) {
            CloudflareCredentialSheet(cloudflare: cloudflare)
        }
        .alert("Log out of Tailscale?", isPresented: $isConfirmingTailscaleLogOut) {
            Button("Log Out", role: .destructive) {
                serverController.logOutOfRemoteAccess()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your devices can't connect until iMCP logs in again.")
        }
        .alert("Log out of Cloudflare?", isPresented: $isConfirmingCloudflareLogOut) {
            Button("Log Out", role: .destructive) {
                cloudflare.logOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the tunnel and removes the saved sign-in.")
        }
    }

    // MARK: Tailscale

    private func tailscaleSection(_ choice: RemoteChoice) -> some View {
        Section {
            LabeledContent {
                tailscaleBadge(serverController.remoteAccessState)
            } label: {
                RowLabel(title: "Status") {
                    SettingsIcon(symbol: choice.settingsSymbol, color: .gray)
                }
            }
            TailscaleChecklistView(remote: remote, compact: true)

            if case .running(let endpoint) = serverController.remoteAccessState {
                if choice == .funnel, endpoint.funnelCapabilityGranted == false {
                    FunnelACLGuidanceView(ipv4Address: endpoint.ipv4Address)
                }
                Button("Log Out of Tailscale…", role: .destructive) { isConfirmingTailscaleLogOut = true }
            } else if case .needsApproval = serverController.remoteAccessState {
                Button("Log Out of Tailscale…", role: .destructive) { isConfirmingTailscaleLogOut = true }
            }
        } header: {
            SectionTitle(title: choice.settingsName, symbol: "checklist")
        }
    }

    @ViewBuilder
    private func tailscaleBadge(_ state: RemoteAccessServer.State) -> some View {
        switch state {
        case .off: StatusBadge(text: "Off")
        case .starting: StatusBadge(text: "Connecting")
        case .needsLogin: StatusBadge(text: "Sign-in needed", kind: .attention)
        case .needsApproval: StatusBadge(text: "Needs approval", kind: .attention)
        case .loggingOut: StatusBadge(text: "Logging out")
        case .failed: StatusBadge(text: "Problem", kind: .bad)
        case .running: StatusBadge(text: "On", kind: .good, symbol: "checkmark")
        }
    }

    // MARK: Cloudflare

    private var cloudflareSection: some View {
        Section {
            LabeledContent {
                cloudflareBadge(cloudflare.state)
            } label: {
                RowLabel(title: "Status") {
                    SettingsIcon(symbol: "cloud", color: .gray)
                }
            }
            CloudflareChecklistView(cloudflare: cloudflare, compact: true)

            if cloudflare.account == nil {
                Button("Use an API Token…") { isShowingCredentialSheet = true }
            } else {
                if case .connected = cloudflare.state, isHostnameDirty {
                    Button("Update and Reconnect") {
                        Task { await cloudflare.provisionAndConnect() }
                    }
                }
                Button("Refresh Domains") { Task { await cloudflare.refreshZones() } }
                Button("Log Out of Cloudflare…", role: .destructive) { isConfirmingCloudflareLogOut = true }
            }
        } header: {
            SectionTitle(title: "Cloudflare Tunnel", symbol: "checklist")
        }
    }

    @ViewBuilder
    private func cloudflareBadge(_ state: CloudflareTunnelController.State) -> some View {
        switch state {
        case .off: StatusBadge(text: "Not signed in")
        case .loggingIn: StatusBadge(text: "Waiting for sign-in")
        case .discoveringZones: StatusBadge(text: "Finding domains")
        case .ready: StatusBadge(text: "Ready")
        case .provisioning: StatusBadge(text: "Setting up")
        case .connected: StatusBadge(text: "Connected", kind: .good, symbol: "checkmark")
        case .failed: StatusBadge(text: "Problem", kind: .bad)
        }
    }

    private var isHostnameDirty: Bool {
        guard let zone = cloudflare.selectedZone,
            let resolved = CloudflareTunnelController.resolvedHostname(
                input: cloudflare.hostnameDraft,
                zoneName: zone.name
            )
        else { return false }
        return resolved != cloudflare.configuredHostname
    }
}

extension RemoteAccessServer.State {
    var endpoint: String? {
        if case .running(let endpoint) = self { endpoint.url } else { nil }
    }
}

/// Shows a copyable Tailscale ACL `nodeAttrs` snippet when the node lacks the `funnel` capability.
private struct FunnelACLGuidanceView: View {
    let ipv4Address: String
    @Environment(\.openURL) private var openURL

    private var snippet: String {
        FunnelPolicy.tailscaleNodeAttrsSnippet(ipv4Address: ipv4Address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tailscale must allow public addresses for this Mac", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            HStack {
                Button("Copy Policy Snippet") {
                    copyToSettingsPasteboard(snippet)
                }
                Button("Open Tailscale Policy…") {
                    if let url = URL(string: "https://login.tailscale.com/admin/acls/file") {
                        openURL(url)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CloudflareCredentialSheet: View {
    @ObservedObject var cloudflare: CloudflareTunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign In to Cloudflare")
                .font(.headline)
            Text(
                "Paste a Cloudflare API token (with Zone:Read, DNS:Edit, and Cloudflare Tunnel:Edit permissions) or paste the contents of `cert.pem`."
            )
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $input)
                .font(.body.monospaced())
                .frame(height: 110)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button("Import cert.pem…") {
                    chooseCertFile()
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    let value = input
                    dismiss()
                    Task { await cloudflare.logIn(credentialInput: value) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseCertFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Select your Cloudflare cert.pem file (for example ~/.cloudflared/cert.pem)."
        if panel.runModal() == .OK, let url = panel.url {
            dismiss()
            Task { await cloudflare.importCertPEM(from: url) }
        }
    }
}
