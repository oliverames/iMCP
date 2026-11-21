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
    /// Whether `imcp-server`'s direct parent is the app's own main executable or a helper
    /// inside its bundle with the same signer. Anything else between the app and
    /// `imcp-server` (an interpreter, a script host, a differently signed binary)
    /// could run code that the app's signature doesn't vouch for.
    var hasTrustedParent: Bool = true

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.bundlePath == rhs.bundlePath && lhs.teamIdentifier == rhs.teamIdentifier
            && lhs.teamName == rhs.teamName && lhs.requirement == rhs.requirement
            && lhs.isAppleSigned == rhs.isAppleSigned && lhs.isAdHocSigned == rhs.isAdHocSigned
            && lhs.hasTrustedParent == rhs.hasTrustedParent
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
        guard requirement != nil, bundlePath != nil, !isAdHocSigned, hasTrustedParent,
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

    // MARK: - Direct parent policy

    /// The signature facts about a process, read from the running code.
    struct ProcessSigner: Equatable, Sendable {
        var isValid: Bool
        var teamIdentifier: String?
        var isAppleSigned: Bool
    }

    /// The process-tree and signature lookups that the parent policy needs.
    /// Tests replace them with a fake tree.
    struct ProcessLookup {
        var parentPID: (pid_t) -> pid_t?
        var executablePath: (pid_t) -> String?
        var signer: (pid_t) -> ProcessSigner?
        /// The path of the main executable of the bundle at a path.
        var mainExecutable: (String) -> String?

        static let system = ProcessLookup(
            parentPID: { processParentAndName($0)?.ppid },
            executablePath: processExecutablePath,
            signer: processSigner,
            mainExecutable: { Bundle(path: $0)?.executablePath.map(canonical) }
        )
    }

    /// Interpreters and script hosts. Even inside a bundle, one of these runs
    /// whatever script it's given, so it never gets the app's trust.
    static let interpreterProcessNames: Set<String> = [
        "node", "nodejs", "python", "python3", "ruby", "perl", "php", "deno", "bun", "java",
        "lua", "osascript", "automator", "shortcuts", "wish", "tclsh", "swift", "npx", "uv",
    ]

    /// Whether `imcp-server`'s direct parent may carry the app's trust:
    /// the app's own main executable, or the executable of a helper app nested in its
    /// bundle that is validly signed by the same team. Any other parent
    /// falls back to the approval dialog.
    static func hasTrustedParent(
        of child: pid_t,
        for app: ResponsibleApp,
        responsible: pid_t,
        lookup: ProcessLookup = .system
    ) -> Bool {
        guard let bundlePath = app.bundlePath,
            let parent = lookup.parentPID(child), parent > 1,
            let rawPath = lookup.executablePath(parent)
        else { return false }
        let path = canonical(rawPath)
        let bundle = canonical(bundlePath)
        let name = (path as NSString).lastPathComponent.lowercased()
        guard !shellProcessNames.contains(name), !interpreterProcessNames.contains(name) else { return false }

        if parent == responsible {
            return lookup.mainExecutable(bundle).map(canonical) == path
        }
        guard path.hasPrefix(bundle + "/Contents/") else { return false }
        // The executable must sit in a helper app nested in the bundle,
        // not loose among the bundle's resources or frameworks.
        let relative = path.dropFirst(bundle.count + 1)
        let components = relative.split(separator: "/").dropLast()
        guard components.contains(where: { $0.hasSuffix(".app") }) else { return false }
        guard let signer = lookup.signer(parent), signer.isValid else { return false }
        if app.isAppleSigned { return signer.isAppleSigned }
        guard let team = app.teamIdentifier else { return false }
        return signer.teamIdentifier == team
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func processExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processSigner(_ pid: pid_t) -> ProcessSigner? {
        let attributes: [CFString: Any] = [kSecGuestAttributePid: pid]
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess,
            let guest
        else { return nil }
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else {
            return ProcessSigner(isValid: false, teamIdentifier: nil, isAppleSigned: false)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let info = info as? [String: Any]
        else { return nil }
        var apple: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &apple)
        let isApple = apple.map { SecCodeCheckValidity(guest, [], $0) == errSecSuccess } ?? false
        return ProcessSigner(
            isValid: true,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            isAppleSigned: isApple
        )
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
        guard var app = ResponsibleApp(staticCode: staticCode, reference: CodeReference(running: guest)) else {
            return nil
        }
        app.hasTrustedParent = hasTrustedParent(of: pid, for: app, responsible: responsible)
        if !app.hasTrustedParent {
            Logger.server.notice(
                "Parent of \(pid) isn't the main executable or a same-team helper of \(app.name); asking instead of trusting its signature"
            )
        }
        return app
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
