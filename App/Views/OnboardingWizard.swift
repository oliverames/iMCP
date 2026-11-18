import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Guided setup for services, remote tunnels, iPhone pairing, approvals, and connecting AI apps.
///
/// Each step is a grouped `Form`. The title bar shows the step, and Back and Continue are at the bottom. Everything here is also in Settings;
/// the assistant only puts the first-run choices in order.
struct OnboardingWizardView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    let onFinish: () -> Void

    @State private var step: Step

    init(
        serverController: ServerController,
        isEnabled: Binding<Bool>,
        initialStep: Step = .services,
        onFinish: @escaping () -> Void
    ) {
        self.serverController = serverController
        self._isEnabled = isEnabled
        self._step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    enum Step: Int, CaseIterable, Identifiable {
        case services, remote, mobile, approvals, apps

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .services: "Services"
            case .remote: "Remote"
            case .mobile: "iPhone"
            case .approvals: "Approvals"
            case .apps: "Apps"
            }
        }
    }

    var body: some View {
        Group {
            switch step {
            case .services:
                ServicesStepView(serverController: serverController, isEnabled: $isEnabled)
            case .remote:
                RemoteStepView(serverController: serverController, cloudflare: serverController.cloudflareTunnel)
            case .mobile:
                MobileStepView()
            case .approvals:
                ApprovalsStepView(serverController: serverController)
            case .apps:
                AppsStepView(serverController: serverController)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Set Up iMCP")
        .navigationSubtitle("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
        .modifier(WizardScrollEdge())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardFooter(step: $step, onFinish: onFinish)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 600)
    }
}

// MARK: - Footer and glass

/// Back, Continue, and Close. The buttons are glass on macOS 26 and later,
/// where the system keeps them legible over the scrolling form, and bordered buttons on a bar before that.
private struct WizardFooter: View {
    @Binding var step: OnboardingWizardView.Step
    let onFinish: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer { buttons.padding() }
        } else {
            buttons.padding().background(.bar)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Close", action: onFinish)
                .keyboardShortcut(.cancelAction)
                .modifier(WizardButtonStyle(isProminent: false))

            Spacer()

            if let previous = OnboardingWizardView.Step(rawValue: step.rawValue - 1) {
                Button("Back") { step = previous }
                    .modifier(WizardButtonStyle(isProminent: false))
            }

            if let next = OnboardingWizardView.Step(rawValue: step.rawValue + 1) {
                Button("Continue") { step = next }
                    .keyboardShortcut(.defaultAction)
                    .modifier(WizardButtonStyle(isProminent: true))
            } else {
                Button("Done", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .modifier(WizardButtonStyle(isProminent: true))
            }
        }
    }
}

private struct WizardButtonStyle: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Fades the form out softly under the footer, so the glass buttons stay legible.
private struct WizardScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
    }
}

// MARK: - Services

private struct ServicesStepView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool

    var body: some View {
        let configs = serverController.computedServiceConfigs

        Form {
            Section {
                Toggle("Enable MCP Server", isOn: $isEnabled)
            } footer: {
                Text("AI apps can use iMCP only while the server is on.")
            }

            Section {
                ForEach(configs) { config in
                    Toggle(
                        isOn: Binding(
                            get: { config.binding.wrappedValue },
                            set: { serverController.setService(config, enabled: $0) }
                        )
                    ) {
                        Label(config.name, systemImage: config.iconName)
                    }
                }
            } header: {
                HStack {
                    Text("Services")
                    Spacer()
                    Button("Turn On All Recommended") {
                        isEnabled = true
                        for config in configs where !(config.service is HomeService) {
                            if !config.binding.wrappedValue {
                                serverController.setService(config, enabled: true)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text(
                    "macOS asks for permission the first time each service turns on. Home stays off until you turn it on yourself."
                )
            }
            .disabled(!isEnabled)
        }
    }
}

// MARK: - Remote tunnels

private struct RemoteStepView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var cloudflare: CloudflareTunnelController
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Text(
                    "Cloud apps such as claude.ai, Claude Duet, and Muse reach your Mac over an encrypted HTTPS tunnel and OAuth. This is optional; skip it if you only use apps on this Mac."
                )
                .foregroundStyle(.secondary)
            }

            cloudflareSection
            tailscaleSection
        }
    }

    // MARK: Cloudflare

    private var cloudflareSection: some View {
        Section {
            if cloudflare.account == nil {
                LabeledContent {
                    Button("Log In…") {
                        Task { await cloudflare.logInWithBrowser() }
                    }
                    .disabled(!cloudflare.isBinaryAvailable || cloudflare.state == .loggingIn)
                } label: {
                    Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
                }
                if cloudflare.detectedCertURL != nil {
                    LabeledContent("Cloudflare account found on this Mac") {
                        Button("Use It") {
                            Task { await cloudflare.useDetectedCert() }
                        }
                    }
                }
            } else {
                if cloudflare.zones.count > 1 {
                    Picker("Domain", selection: $cloudflare.selectedZoneID) {
                        ForEach(cloudflare.zones) { zone in
                            Text(zone.name).tag(zone.id)
                        }
                    }
                }
                TextField("Hostname", text: $cloudflare.hostnameDraft, prompt: Text("imcp.example.com"))
                if let url = cloudflare.state.activeURL {
                    LabeledContent {
                        Button("Copy URL") { copyToPasteboard(url) }
                    } label: {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(url)
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent("Tunnel") {
                        Button("Set Up Tunnel") {
                            Task { await cloudflare.provisionAndConnect() }
                        }
                    }
                }
            }
            if case .failed(let reason) = cloudflare.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Cloudflare Tunnel")
        } footer: {
            Text("Opens iMCP on your own Cloudflare domain, without Tailscale.")
        }
    }

    // MARK: Tailscale

    private var tailscaleSection: some View {
        Section {
            Toggle(
                "Use Tailscale",
                isOn: Binding(
                    get: { serverController.isRemoteAccessEnabled },
                    set: { serverController.isRemoteAccessEnabled = $0 }
                )
            )

            if serverController.isRemoteAccessEnabled {
                switch serverController.remoteAccessState {
                case .needsLogin(let url):
                    LabeledContent {
                        if let url {
                            Button("Sign In…") { openURL(url) }
                        } else {
                            Button("Get Sign-In Link") { serverController.restartRemoteAccessNode() }
                        }
                    } label: {
                        Label("Sign in to connect this Mac", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                case .running(let endpoint):
                    LabeledContent {
                        Text(endpoint.ipv4Address)
                    } label: {
                        Label("Connected to your tailnet", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Toggle(
                        "Public access with Funnel",
                        isOn: Binding(
                            get: { serverController.isRemoteAccessFunnelEnabled },
                            set: { serverController.isRemoteAccessFunnelEnabled = $0 }
                        )
                    )
                    if case .active(let funnelURL) = endpoint.funnel {
                        LabeledContent {
                            Button("Copy URL") { copyToPasteboard(funnelURL) }
                        } label: {
                            Text(funnelURL)
                                .textSelection(.enabled)
                        }
                    }
                case .starting:
                    Label("Starting…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                case .needsApproval:
                    Label(
                        "Waiting for approval in your Tailscale admin console",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(.orange)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                case .off, .loggingOut:
                    EmptyView()
                }
            }
        } header: {
            Text("Tailscale")
        } footer: {
            Text(
                "Adds iMCP to your tailnet as its own device. Funnel also opens a public HTTPS address, so cloud apps can connect."
            )
        }
    }
}

// MARK: - iPhone and iPad

private struct MobileStepView: View {
    @State private var pairedDevices: [MobileDevice] = []
    @State private var connectedDevice: MobileDevice?
    @State private var pairingCode: MobilePairingCode?
    @State private var pairingExpires: Date?
    @State private var pairingError: String?

    var body: some View {
        Form {
            Section {
                if pairedDevices.isEmpty {
                    Text("No iPhone or iPad is paired yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairedDevices) { device in
                        let isConnected = connectedDevice?.id == device.id
                        LabeledContent {
                            Text(isConnected ? "Connected" : "Paired")
                        } label: {
                            Label(device.name, systemImage: isConnected ? "iphone.radiowaves.left.and.right" : "iphone")
                        }
                    }
                }

                if pairingCode == nil {
                    LabeledContent {
                        Button(pairedDevices.isEmpty ? "Pair…" : "Pair Another…") {
                            beginPairing()
                        }
                    } label: {
                        Text("Pair a device")
                    }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text(
                    "The iMCP app for iPhone shares Health and Alarms, shows every tool call, and lets you approve requests from your phone."
                )
            }

            if let pairingCode, let pairingExpires {
                Section {
                    if let qr = qrImage(pairingCode.url.absoluteString) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Pairing code")
                    }
                    LabeledContent("Expires") {
                        Text(pairingExpires, format: .dateTime.hour().minute())
                    }
                    LabeledContent("Pairing link") {
                        Button("Copy") { copyToPasteboard(pairingCode.url.absoluteString) }
                    }
                } header: {
                    Text("Scan in the iMCP app")
                }
            }

            if let pairingError {
                Section {
                    Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            pairedDevices = await MobileService.shared.devices
            connectedDevice = await MobileService.shared.connectedDevice
        }
    }

    private func beginPairing() {
        Task {
            do {
                pairingCode = try await MobileService.shared.beginPairing()
                pairingExpires = Date().addingTimeInterval(MobileService.pairingLifetime)
                pairingError = nil
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

// MARK: - Approvals

private struct ApprovalsStepView: View {
    @ObservedObject var serverController: ServerController

    var body: some View {
        let mode = Binding(
            get: { serverController.approvalMode },
            set: { serverController.approvalMode = $0 }
        )

        Form {
            Section {
                Picker("Approval mode", selection: mode) {
                    ForEach(ApprovalMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Before a tool runs")
            } footer: {
                Text(mode.wrappedValue.summary)
            }
        }
    }
}

// MARK: - Connect apps

private struct AppsStepView: View {
    @ObservedObject var serverController: ServerController

    var body: some View {
        let publicURLs = serverController.activePublicURLs

        Form {
            Section {
                LabeledContent {
                    Button("Set Up…") {
                        ClaudeDesktop.showConfigurationPanel(serverController: serverController)
                    }
                } label: {
                    Label("Claude Desktop", systemImage: "macwindow")
                }
                LabeledContent {
                    Button("Set Up…") {
                        ClaudeCode.showConfigurationPanel(serverController: serverController)
                    }
                } label: {
                    Label("Claude Code", systemImage: "terminal")
                }
            } header: {
                Text("Apps on this Mac")
            } footer: {
                Text(
                    "The first time an app connects, iMCP asks once: Allow Once or Always Allow."
                )
            }

            Section {
                if publicURLs.isEmpty {
                    Text("Turn on Cloudflare Tunnel or Tailscale Funnel in the Remote step to get a connector URL.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(publicURLs, id: \.url) { item in
                        LabeledContent {
                            Button("Copy URL") { copyToPasteboard(item.url) }
                        } label: {
                            Text(item.provider)
                            Text(item.url)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Cloud apps")
            } footer: {
                if !publicURLs.isEmpty {
                    Text(
                        "In claude.ai, open Settings, then Connectors, then Add custom connector, and paste the URL. Claude Duet and Muse take the same URL as a custom MCP connector. Approve the connection once in iMCP."
                    )
                }
            }
        }
    }
}

private func copyToPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    _ = NSSound.play(.pop)
}
