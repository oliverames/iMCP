import Darwin
import Foundation
import OSLog
import Security

// The system tracks which app is responsible for each process,
// so that a helper that an app launches is attributed to the app.
// There's no public header for this function.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// A running code identity that can be checked against a designated requirement.
final class CodeReference: @unchecked Sendable {
    private enum Source {
        case running(SecCode)
        case onDisk(SecStaticCode)
    }

    private let source: Source

    init(running code: SecCode) { source = .running(code) }
    init(onDisk code: SecStaticCode) { source = .onDisk(code) }

    /// Whether the code is validly signed and satisfies `requirement`.
    func satisfies(_ requirement: String) -> Bool {
        guard let compiled = try? CodeRequirement.compile(requirement) else { return false }
        switch source {
        case .running(let code):
            return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
        case .onDisk(let code):
            return SecStaticCodeCheckValidity(code, [], compiled) == errSecSuccess
        }
    }
}

/// The app that is responsible for the `imcp-server` process that connected,
/// with the facts that iMCP read from its code signature.
///
/// Unlike the name that a client reports, none of this is chosen by the client.
struct ResponsibleApp: Equatable, Sendable {
    var name: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var teamIdentifier: String?
    /// The organization on the signing certificate, such as "Anthropic, PBC".
    var teamName: String?
    /// The app's designated requirement.
    var requirement: String?
    var isAppleSigned: Bool
    var isAdHocSigned: Bool
    /// The code to check trusted requirements against.
    var code: CodeReference?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.bundlePath == rhs.bundlePath && lhs.teamIdentifier == rhs.teamIdentifier
            && lhs.teamName == rhs.teamName && lhs.requirement == rhs.requirement
            && lhs.isAppleSigned == rhs.isAppleSigned && lhs.isAdHocSigned == rhs.isAdHocSigned
    }

    /// Apps that run whatever the person types or scripts,
    /// so trusting one would trust every program that runs inside it.
    static let shellHostBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.apple.ScriptEditor2",
    ]

    /// Whether trusting this app's signature identifies one client,
    /// rather than everything that runs inside it.
    ///
    /// An app that is unsigned, signed ad hoc, not an app bundle,
    /// or a terminal can't be trusted this way.
    var isTrustableBySignature: Bool {
        guard requirement != nil, bundlePath != nil, !isAdHocSigned,
            teamIdentifier != nil || isAppleSigned
        else { return false }
        if let bundleIdentifier, Self.shellHostBundleIdentifiers.contains(bundleIdentifier) { return false }
        return true
    }

    /// The signer to show, such as "Anthropic, PBC (Q6L2SF6YDW)".
    var verifiedSigner: String? {
        if isAppleSigned { return "Apple" }
        switch (teamName, teamIdentifier) {
        case (let name?, let team?): return "\(name) (\(team))"
        case (nil, let team?): return team
        default: return nil
        }
    }

    /// Process names of interactive/scripting shells. If any intermediate ancestor between
    /// `imcp-server` and its responsible app is a shell, trusting the app's signature would
    /// trust arbitrary shell commands run inside it.
    static let shellProcessNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "tcsh", "dash", "ksh", "osascript",
    ]

    /// Verifies that `ancestor` is in `child`'s actual parent-process chain and that no
    /// intermediate process between them is a shell. This ensures the responsible app is
    /// genuinely an ancestor of the process holding `imcp-server`'s stdio.
    static func isDirectAncestorWithoutShell(
        child: pid_t,
        ancestor: pid_t,
        parentAndName: (pid_t) -> (ppid: pid_t, name: String)? = processParentAndName
    ) -> Bool {
        guard child > 0, ancestor > 0 else { return false }
        if child == ancestor { return true }
        var current = child
        var seen = Set<pid_t>([child])
        for _ in 0 ..< 32 {
            guard let info = parentAndName(current) else { return false }
            let parent = info.ppid
            if parent == ancestor { return true }
            if parent <= 1 || !seen.insert(parent).inserted { return false }
            if let parentInfo = parentAndName(parent),
                shellProcessNames.contains(parentInfo.name.lowercased())
            {
                return false
            }
            current = parent
        }
        return false
    }

    private static func processParentAndName(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return (pid_t(bsd.pbi_ppid), name)
    }

    // MARK: - Resolving

    /// Returns the app responsible for process `pid`, or `nil` if there is none to identify.
    static func resolve(responsibleFor pid: pid_t) -> ResponsibleApp? {
        var responsible = responsibility_get_pid_responsible_for_pid(pid)
        if responsible <= 0 { responsible = pid }
        guard isDirectAncestorWithoutShell(child: pid, ancestor: responsible) else {
            Logger.server.notice(
                "Responsible process \(responsible) is not a direct non-shell ancestor of \(pid)"
            )
            return nil
        }
        let attributes: [CFString: Any] = [
            kSecGuestAttributePid: responsible,
            kSecGuestAttributeDynamicCode: true,
        ]
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess,
            let guest
        else {
            Logger.server.notice("No code signature for responsible process \(responsible)")
            return nil
        }
        // A process that isn't validly signed gets no identity.
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return ResponsibleApp(staticCode: staticCode, reference: CodeReference(running: guest))
    }

    /// Reads the app at `url`, for tests and settings.
    static func read(appAt url: URL) -> ResponsibleApp? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        return ResponsibleApp(staticCode: staticCode, reference: CodeReference(onDisk: staticCode))
    }

    private init?(staticCode: SecStaticCode, reference: CodeReference) {
        var path: CFURL?
        SecCodeCopyPath(staticCode, [], &path)
        let url = path as URL?
        let bundle = url.flatMap { $0.pathExtension == "app" ? Bundle(url: $0) : nil }

        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let info = info as? [String: Any]
        else { return nil }

        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        var designated: SecRequirement?
        SecCodeCopyDesignatedRequirement(staticCode, [], &designated)
        var designatedText: CFString?
        if let designated { SecRequirementCopyString(designated, [], &designatedText) }

        var apple: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &apple)
        let isApple = apple.map { SecStaticCodeCheckValidity(staticCode, [], $0) == errSecSuccess } ?? false

        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let summary = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }

        let fallbackName = identifier ?? url?.deletingPathExtension().lastPathComponent ?? "Unknown App"
        self.init(
            name: bundle.flatMap { url in
                FileManager.default.displayName(atPath: url.bundlePath).replacingOccurrences(of: ".app", with: "")
            } ?? fallbackName,
            bundleIdentifier: bundle?.bundleIdentifier,
            bundlePath: bundle?.bundlePath,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            teamName: summary.flatMap(Self.organization(fromCertificateSummary:)),
            requirement: designatedText as String?,
            isAppleSigned: isApple,
            isAdHocSigned: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            code: reference
        )
    }

    init(
        name: String,
        bundleIdentifier: String?,
        bundlePath: String?,
        teamIdentifier: String?,
        teamName: String?,
        requirement: String?,
        isAppleSigned: Bool,
        isAdHocSigned: Bool,
        code: CodeReference?
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.teamIdentifier = teamIdentifier
        self.teamName = teamName
        self.requirement = requirement
        self.isAppleSigned = isAppleSigned
        self.isAdHocSigned = isAdHocSigned
        self.code = code
    }

    /// Extracts "Anthropic, PBC" from "Developer ID Application: Anthropic, PBC (Q6L2SF6YDW)".
    static func organization(fromCertificateSummary summary: String) -> String? {
        guard let colon = summary.range(of: ": ") else { return nil }
        var name = String(summary[colon.upperBound...])
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        return name.isEmpty ? nil : name
    }
}
