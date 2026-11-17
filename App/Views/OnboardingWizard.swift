import AppKit
import SwiftUI

/// Guided setup assistant for services, remote tunnels, iPhone pairing, approval mode, and connecting AI apps.
struct OnboardingWizardView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    let onFinish: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var step = 0
    @State private var pairedDevices: [MobileDevice] = []
    @State private var connectedDevice: MobileDevice?
    @State private var pairingCode: MobilePairingCode?
    @State private var pairingExpires: Date?
    @State private var pairingError: String?

    private static let stepTitles = [
        "Services",
        "Remote Tunnels",
        "iPhone & iPad",
        "Approval Mode",
        "Connect Apps",
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set Up iMCP")
                            .font(.title2.weight(.semibold))
                        Text("Connect your Mac and iPhone services to local and cloud AI apps.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                WizardStepIndicator(step: $step, titles: Self.stepTitles)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                Group {
                    switch step {
                    case 0:
                        servicesStep
                    case 1:
                        tunnelsStep
                    case 2:
                        mobileStep
                    case 3:
                        approvalModeStep
                    default:
                        connectAppsStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Close") {
                    onFinish()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if step > 0 {
                    Button("Back") {
                        step -= 1
                    }
                }

                if step < Self.stepTitles.count - 1 {
                    Button("Continue") {
                        step += 1
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Done") {
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 660, height: 590)
    }

    // MARK: - Step 0: Services

    private var servicesStep: some View {
        let configs = serverController.computedServiceConfigs

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Choose Which Services iMCP Can Use")
                    .font(.headline)
                Text(
                    "Turn on the Apple apps and system services you want to expose. macOS asks once for permission the first time each service turns on."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Toggle("Enable MCP Server", isOn: $isEnabled)
                    .toggleStyle(.switch)
                Spacer()
                Button("Enable All Recommended") {
                    isEnabled = true
                    for config in configs where !(config.service is HomeService) {
                        if !config.binding.wrappedValue {
                            serverController.setService(config, enabled: true)
                        }
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 8) {
                ForEach(configs) { config in
                    HStack(spacing: 10) {
                        ServiceIcon(config: config, isOn: config.binding.wrappedValue, size: 22)
                        Text(config.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Toggle(
                            config.name,
                            isOn: Binding(
                                get: { config.binding.wrappedValue },
                                set: { serverController.setService(config, enabled: $0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                }
            }
        }
    }

    // MARK: - Step 1: Remote Tunnels

    private var tunnelsStep: some View {
        OnboardingTunnelsStepView(
            serverController: serverController,
            cloudflare: serverController.cloudflareTunnel
        )
    }

    // MARK: - Step 2: iPhone & iPad

    private var mobileStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("3. Pair Your iPhone or iPad")
                    .font(.headline)
                Text(
                    "The iMCP iOS app syncs Health and Alarms data, shows a live Activity History of every tool call, and lets you approve requests remotely over Local Wi-Fi, Tailscale VPN, Tailscale Funnel, or Cloudflare."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                if pairedDevices.isEmpty {
                    Text("No iPhone or iPad is paired yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairedDevices) { device in
                        HStack {
                            Image(systemName: "iphone")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.subheadline.weight(.medium))
                                Text(connectedDevice?.id == device.id ? "Connected" : "Paired (ready to connect)")
                                    .font(.caption)
                                    .foregroundStyle(connectedDevice?.id == device.id ? .green : .secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                if let pairingCode, let pairingExpires {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = qrImage(pairingCode.url.absoluteString) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 140, height: 140)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan this code in the iMCP iOS app.")
                                .font(.subheadline.weight(.medium))
                            Text("Expires at \(pairingExpires.formatted(date: .omitted, time: .shortened)).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Copy Pairing Link") {
                                copyToPasteboard(pairingCode.url.absoluteString)
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    Button(pairedDevices.isEmpty ? "Pair iPhone or iPad…" : "Pair Another Device…") {
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
                }

                if let pairingError {
                    Text(pairingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
        .task {
            pairedDevices = await MobileService.shared.devices
            connectedDevice = await MobileService.shared.connectedDevice
        }
    }

    // MARK: - Step 3: Approval Mode

    private var approvalModeStep: some View {
        let selectedMode = serverController.approvalMode

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("4. Choose How Tool Calls Are Approved")
                    .font(.headline)
                Text(
                    "Control whether iMCP prompts on your Mac and iPhone before actions run, or delegates prompting to your AI app."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(ApprovalMode.allCases) { mode in
                    Button {
                        serverController.approvalMode = mode
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedMode == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedMode == mode ? Color.accentColor : .secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(mode.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedMode == mode ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Step 4: Connect Apps

    private var connectAppsStep: some View {
        let publicURLs = serverController.activePublicURLs

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("5. Connect Your Local and Cloud Agents")
                    .font(.headline)
                Text(
                    "The first time any client connects, iMCP shows a single prompt where you can choose Allow Once or Always Allow."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Apps on This Mac")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    Button("Set Up Claude Desktop…") {
                        ClaudeDesktop.showConfigurationPanel(serverController: serverController)
                    }
                    Button("Set Up Claude Code…") {
                        ClaudeCode.showConfigurationPanel(serverController: serverController)
                    }
                }
                Text("Local apps are verified by code signature or an automatic local credential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 10) {
                Text("Cloud Connectors (claude.ai, Claude Duet, Muse)")
                    .font(.subheadline.weight(.semibold))

                if publicURLs.isEmpty {
                    Text("Turn on Cloudflare Tunnel or Tailscale Funnel in Step 2 to get your public HTTPS connector URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(publicURLs, id: \.url) { item in
                        HStack {
                            Text(item.provider)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(item.url)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Button("Copy URL") {
                                copyToPasteboard(item.url)
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("• **claude.ai**: Open Settings -> Connectors -> Add custom connector, paste the URL, and click Connect.")
                            .font(.caption)
                        Text("• **Claude Duet**: Add a custom MCP connector with the URL above and approve once in iMCP.")
                            .font(.caption)
                        Text("• **Muse**: Add the MCP server URL above (supports OAuth 2.1).")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        _ = NSSound.play(.pop)
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

private struct OnboardingTunnelsStepView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var cloudflare: CloudflareTunnelController
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("2. Set Up Remote Tunnels for Cloud Agents")
                    .font(.headline)
                Text(
                    "Cloud agents like claude.ai, Claude Duet, and Muse reach your Mac over an encrypted HTTPS tunnel with OAuth 2.1. Sign in to Cloudflare or Tailscale and iMCP provisions the rest."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            // Cloudflare Tunnel Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Cloudflare Tunnel (Custom Domain)", systemImage: "cloud.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if case .connected(let url, _, _) = cloudflare.state {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption.weight(.medium))
                        Button("Copy URL") {
                            copyToPasteboard(url)
                        }
                        .controlSize(.small)
                    }
                }

                Text("Exposes iMCP on your own Cloudflare domain (such as imcp.amesvt.com) without needing Tailscale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if cloudflare.account == nil {
                    HStack {
                        Button("Log In with Browser") {
                            Task { await cloudflare.logInWithBrowser() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!cloudflare.isBinaryAvailable || cloudflare.state == .loggingIn)

                        if cloudflare.detectedCertURL != nil {
                            Button("Use Detected Account") {
                                Task { await cloudflare.useDetectedCert() }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        if cloudflare.zones.count > 1 {
                            Picker("Domain", selection: $cloudflare.selectedZoneID) {
                                ForEach(cloudflare.zones) { zone in
                                    Text(zone.name).tag(zone.id)
                                }
                            }
                            .frame(width: 200)
                        }
                        TextField("Hostname", text: $cloudflare.hostnameDraft, prompt: Text("imcp.example.com"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)

                        if case .connected(let url, _, _) = cloudflare.state {
                            Text(url)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Button("Provision & Connect") {
                                Task { await cloudflare.provisionAndConnect() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            // Tailscale Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Tailscale & Tailscale Funnel", systemImage: "network")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle(
                        "Enable Tailscale",
                        isOn: Binding(
                            get: { serverController.isRemoteAccessEnabled },
                            set: { serverController.isRemoteAccessEnabled = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }

                Text(
                    "Joins your tailnet as its own device for private VPN access, and optionally opens a public .ts.net HTTPS address through Tailscale Funnel."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if serverController.isRemoteAccessEnabled {
                    switch serverController.remoteAccessState {
                    case .needsLogin(let url):
                        HStack {
                            Text("Sign in with your Tailscale account to connect this Mac.")
                                .font(.caption)
                            Spacer()
                            if let url {
                                Button("Sign In to Tailscale…") { openURL(url) }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Get Login Link") { serverController.restartRemoteAccessNode() }
                            }
                        }
                    case .running(let endpoint):
                        HStack {
                            Label("Connected on Tailnet (\(endpoint.ipv4Address))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Spacer()
                            Toggle(
                                "Public Funnel",
                                isOn: Binding(
                                    get: { serverController.isRemoteAccessFunnelEnabled },
                                    set: { serverController.isRemoteAccessFunnelEnabled = $0 }
                                )
                            )
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        if case .active(let funnelURL) = endpoint.funnel {
                            HStack {
                                Text(funnelURL)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Copy URL") { copyToPasteboard(funnelURL) }
                                    .controlSize(.small)
                            }
                        }
                    case .starting:
                        Text("Starting Tailscale node…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .needsApproval:
                        Text("Waiting for device approval in your Tailscale admin console.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .failed(let reason):
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .off, .loggingOut:
                        EmptyView()
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        _ = NSSound.play(.pop)
    }
}

private struct WizardStepIndicator: View {
    @Binding var step: Int
    let titles: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button {
                    step = index
                } label: {
                    HStack(spacing: 5) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.bold))
                            .frame(width: 18, height: 18)
                            .background(
                                Circle().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.2))
                            )
                            .foregroundStyle(index == step ? Color.white : .secondary)
                        Text(title)
                            .font(.caption.weight(index == step ? .semibold : .regular))
                            .foregroundStyle(index == step ? .primary : .secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < titles.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
