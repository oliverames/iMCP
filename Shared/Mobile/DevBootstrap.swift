import CryptoKit
import Foundation

/// Build-time dev bootstrap configuration sourced from `GeneratedBootstrapSecrets`.
///
/// Populated locally from the 1Password `Development` vault via
/// `Scripts/generate-bootstrap-secrets.sh`. When secrets are absent (e.g. CI),
/// `isConfigured` is `false` and all bootstrap helpers are no-ops.
enum DevBootstrap {
    static let iosUnpairedDefaultsKey = "devBootstrap.iosUnpaired"
    static let macUnpairedDeviceIDsKey = "devBootstrap.macUnpairedDeviceIDs"
    static let macApprovalModeSeededKey = "devBootstrap.macApprovalModeSeeded"
    static let macCloudflareSeededKey = "devBootstrap.macCloudflareSeeded"

    static var deviceID: String {
        DevBootstrapSecrets.mobileDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var deviceName: String {
        let name = DevBootstrapSecrets.mobileDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Oliver's iPhone" : name
    }

    static var deviceKeyData: Data? {
        guard let data = Data(base64Encoded: DevBootstrapSecrets.mobileDeviceKeyBase64), data.count >= 16 else {
            return nil
        }
        return data
    }

    static var deviceKey: SymmetricKey? {
        deviceKeyData.map(SymmetricKey.init(data:))
    }

    static var isConfigured: Bool {
        DevBootstrapSecrets.isConfigured && !deviceID.isEmpty && deviceKeyData != nil
    }

    static var macBonjourService: String {
        let trimmed = DevBootstrapSecrets.macBonjourService.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        #if os(macOS)
            return "iMCP on \(Host.current().localizedName ?? "Mac")"
        #else
            return "iMCP on MacBook Pro"
        #endif
    }

    static var tailnetHost: String? {
        let trimmed = DevBootstrapSecrets.tailnetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var tailnetIP: String? {
        let trimmed = DevBootstrapSecrets.tailnetIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var tailnetMobilePort: UInt16 {
        DevBootstrapSecrets.tailnetMobilePort > 0
            ? DevBootstrapSecrets.tailnetMobilePort
            : MobileLink.defaultRemotePort
    }

    static var funnelMobileURL: String? {
        MobileLink.normalizedWebSocketURL(DevBootstrapSecrets.funnelMobileURL)
    }

    static var cloudflareHostname: String? {
        let trimmed = DevBootstrapSecrets.cloudflareHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var cloudflareMobileURL: String? {
        MobileLink.normalizedWebSocketURL(DevBootstrapSecrets.cloudflareMobileURL)
    }

    static var cloudflareTunnelID: String? {
        let trimmed = DevBootstrapSecrets.cloudflareTunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var cloudflareTunnelName: String? {
        let trimmed = DevBootstrapSecrets.cloudflareTunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var cloudflareTunnelToken: String? {
        let trimmed = DevBootstrapSecrets.cloudflareTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var cloudflareCertData: Data? {
        guard !DevBootstrapSecrets.cloudflareCertPEMBase64.isEmpty,
            let data = Data(base64Encoded: DevBootstrapSecrets.cloudflareCertPEMBase64),
            !data.isEmpty
        else {
            return nil
        }
        return data
    }

    // MARK: - Mac Bootstrap

    #if os(macOS)
    /// Seeds Cloudflare `cert.pem`, default Cloudflare hostname, mobile Cloudflare URL, and default
    /// approval mode on Oliver's Mac dev builds if not already configured.
    static func seedMacDefaultsAndCertIfNeeded(
        defaults: UserDefaults = .standard,
        containerCertURL: URL
    ) {
        guard isConfigured else { return }

        if let certData = cloudflareCertData,
            !FileManager.default.fileExists(atPath: containerCertURL.path)
        {
            let dir = containerCertURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? certData.write(to: containerCertURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: containerCertURL.path)
        }

        if !defaults.bool(forKey: macCloudflareSeededKey) {
            if let host = cloudflareHostname,
                (defaults.string(forKey: "cloudflareTunnelHostname") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                defaults.set(host, forKey: "cloudflareTunnelHostname")
            }
            if let tunnelID = cloudflareTunnelID,
                (defaults.string(forKey: "cloudflareTunnelID") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                defaults.set(tunnelID, forKey: "cloudflareTunnelID")
            }
            if let tunnelName = cloudflareTunnelName,
                (defaults.string(forKey: "cloudflareTunnelName") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                defaults.set(tunnelName, forKey: "cloudflareTunnelName")
            }
            if defaults.object(forKey: "cloudflareTunnelEnabled") == nil, cloudflareHostname != nil {
                defaults.set(true, forKey: "cloudflareTunnelEnabled")
            }
            if defaults.object(forKey: "remoteAccessEnabled") == nil {
                defaults.set(true, forKey: "remoteAccessEnabled")
            }
            if defaults.object(forKey: "remoteAccessFunnelEnabled") == nil {
                defaults.set(true, forKey: "remoteAccessFunnelEnabled")
            }
            for serviceKey in [
                "alarmsEnabled",
                "calendarEnabled",
                "captureEnabled",
                "contactsEnabled",
                "filesEnabled",
                "healthEnabled",
                "locationEnabled",
                "mailEnabled",
                "mapsEnabled",
                "messagesEnabled",
                "musicEnabled",
                "notesEnabled",
                "phoneEnabled",
                "remindersEnabled",
                "shortcutsEnabled",
                "utilitiesEnabled",
                "voiceMemosEnabled",
                "voicemailEnabled",
                "weatherEnabled",
                "writesEnabled.FilesService",
                "writesEnabled.MessageService",
                "writesEnabled.NotesService",
            ] where defaults.object(forKey: serviceKey) == nil {
                defaults.set(true, forKey: serviceKey)
            }
            if let cfMobile = cloudflareMobileURL,
                (defaults.string(forKey: "mobileCloudflareURL") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                defaults.set(cfMobile, forKey: "mobileCloudflareURL")
            }
            if let funnelMobile = funnelMobileURL,
                (defaults.string(forKey: "mobileFunnelURL") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                defaults.set(funnelMobile, forKey: "mobileFunnelURL")
            }
            if let tsHost = tailnetHost,
                (defaults.string(forKey: "mobileTailnetHost") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                defaults.set(tsHost, forKey: "mobileTailnetHost")
            }
            defaults.set(true, forKey: macCloudflareSeededKey)
        }

        if defaults.object(forKey: "remoteAccessEnabled") == nil {
            defaults.set(true, forKey: "remoteAccessEnabled")
            defaults.set(true, forKey: "remoteAccessFunnelEnabled")
        }
        if defaults.object(forKey: "notesEnabled") == nil {
            for serviceKey in [
                "alarmsEnabled",
                "calendarEnabled",
                "captureEnabled",
                "contactsEnabled",
                "filesEnabled",
                "healthEnabled",
                "locationEnabled",
                "mailEnabled",
                "mapsEnabled",
                "messagesEnabled",
                "musicEnabled",
                "notesEnabled",
                "phoneEnabled",
                "remindersEnabled",
                "shortcutsEnabled",
                "utilitiesEnabled",
                "voiceMemosEnabled",
                "voicemailEnabled",
                "weatherEnabled",
                "writesEnabled.FilesService",
                "writesEnabled.MessageService",
                "writesEnabled.NotesService",
            ] where defaults.object(forKey: serviceKey) == nil {
                defaults.set(true, forKey: serviceKey)
            }
        }

        if !defaults.bool(forKey: macApprovalModeSeededKey) {
            if defaults.string(forKey: ApprovalMode.defaultsKey) == nil {
                ApprovalMode.setCurrent(.agentManaged, defaults: defaults)
            }
            defaults.set(true, forKey: macApprovalModeSeededKey)
        }
    }

    static func isMacDeviceUnpaired(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        let unpaired = defaults.stringArray(forKey: macUnpairedDeviceIDsKey) ?? []
        return unpaired.contains(id)
    }

    static func markMacDeviceUnpaired(_ id: String, defaults: UserDefaults = .standard) {
        var unpaired = defaults.stringArray(forKey: macUnpairedDeviceIDsKey) ?? []
        if !unpaired.contains(id) {
            unpaired.append(id)
            defaults.set(unpaired, forKey: macUnpairedDeviceIDsKey)
        }
    }

    /// Seeds the pre-paired `(deviceID, deviceName, key)` into the Mac's pairing store if absent and not unpaired.
    static func seedMacPairingIfNeeded(
        defaults: UserDefaults = .standard,
        existingDeviceIDs: () -> [String],
        existingKey: (String) -> SymmetricKey?,
        save: (String, String, SymmetricKey) throws -> Void
    ) {
        guard isConfigured, let key = deviceKey else { return }
        guard !isMacDeviceUnpaired(deviceID, defaults: defaults) else { return }
        if existingDeviceIDs().contains(deviceID), existingKey(deviceID) != nil {
            return
        }
        try? save(deviceID, deviceName, key)
    }
    #endif
}
