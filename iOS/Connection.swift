import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

/// What the phone keeps after pairing: its device ID and key, and which Mac it paired with.
struct PhoneCredentials: Codable, Equatable, Sendable {
    var device: String
    var key: Data
    /// The Mac's Bonjour service name.
    var service: String
    var tailnetHost: String?
    var tailnetPort: UInt16?
    var funnelURL: String?
    var cloudflareURL: String?
    /// What the Mac last told this phone to use. Once present, it decides the routes and their order,
    /// and the baked-in bootstrap above is never consulted again.
    var configuration: MobileConfiguration?

    private static let account = "pairing"
    private static let keychainService = "co.dododo.iMCP.iOS"

    static func load() -> PhoneCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let stored = try? JSONDecoder().decode(PhoneCredentials.self, from: data)
        {
            return stored
        }
        guard !MobileAppGroup.defaults.bool(forKey: DevBootstrap.iosUnpairedDefaultsKey),
            DevBootstrap.isConfigured,
            let keyData = DevBootstrap.deviceKeyData
        else {
            return nil
        }
        return PhoneCredentials(
            device: DevBootstrap.deviceID,
            key: keyData,
            service: DevBootstrap.macBonjourService,
            tailnetHost: DevBootstrap.tailnetHost,
            tailnetPort: DevBootstrap.tailnetMobilePort,
            funnelURL: DevBootstrap.funnelMobileURL,
            cloudflareURL: DevBootstrap.cloudflareMobileURL
        )
    }

    func save() throws {
        Self.delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.account,
            // Background delivery can run while the phone is locked after its first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(self),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MobileError("The Keychain refused the pairing (\(status)).")
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    var macName: String {
        if let name = configuration?.macName, !name.isEmpty { return name }
        return service.hasPrefix("iMCP on ") ? String(service.dropFirst("iMCP on ".count)) : service
    }

    var endpoint: NWEndpoint {
        .service(name: service, type: MobileLink.serviceType, domain: "local.", interface: nil)
    }

    private var routes: MobilePhoneRoutes {
        get {
            MobilePhoneRoutes(
                service: service,
                tailnetHost: tailnetHost,
                tailnetPort: tailnetPort,
                funnelURL: funnelURL,
                cloudflareURL: cloudflareURL,
                configuration: configuration
            )
        }
        set {
            service = newValue.service
            tailnetHost = newValue.tailnetHost
            tailnetPort = newValue.tailnetPort
            funnelURL = newValue.funnelURL
            cloudflareURL = newValue.cloudflareURL
            configuration = newValue.configuration
        }
    }

    /// The endpoints to try for `mode`, in order. The Mac's configuration decides once the phone has one;
    /// until then the addresses from pairing or the bootstrap are used.
    func candidates(for mode: MobileTransportMode) -> [MobileTransportCandidate] {
        routes.candidates(for: mode)
    }

    /// Follows `configuration` if it is newer than the one this phone holds, or returns nil.
    func applying(_ configuration: MobileConfiguration) -> PhoneCredentials? {
        guard let updated = routes.applying(configuration) else { return nil }
        var copy = self
        copy.routes = updated
        return copy
    }

    /// Takes what the Mac says in its welcome.
    func updating(from welcome: MobileWelcome) -> PhoneCredentials {
        var copy = self
        copy.routes = routes.updating(from: welcome)
        return copy
    }
}

/// Keeps the device connected to the paired Mac and serves the mobile tools on that connection.
///
/// The phone dials the Mac, because iOS suspends apps and can't accept connections reliably.
/// While the app is open, it reconnects whenever the connection drops.
/// When iOS wakes the app in the background, it connects once,
/// waits until the Mac has pulled the queued changes, and disconnects.
@MainActor
final class PhoneConnection: ObservableObject {
    static let shared = PhoneConnection()

    enum Phase: Equatable {
        case unpaired
        case searching
        case connected
        case failed(String)
    }

    private static let transportModeDefaultsKey = "mobile.transportMode"

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var credentials: PhoneCredentials? = PhoneCredentials.load()
    @Published private(set) var queuedBatches = 0
    @Published private(set) var activeTransport: MobileTransportMode?
    @Published private(set) var transportMode: MobileTransportMode

    private let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "connection")
    private var loop: Task<Void, Never>?
    private var channel: (any MobileTransportChannel)?

    private init() {
        let storedMode =
            MobileAppGroup.defaults.string(forKey: Self.transportModeDefaultsKey)
            .flatMap(MobileTransportMode.init(rawValue:)) ?? .automatic
        self.transportMode = storedMode
        phase = credentials == nil ? .unpaired : .searching
    }

    static var deviceName: String { UIDevice.current.name }

    private var version: String { Bundle.main.shortVersionString ?? "unknown" }

    // MARK: - Transport Configuration

    func setTransportMode(_ mode: MobileTransportMode) {
        guard mode != transportMode else { return }
        transportMode = mode
        MobileAppGroup.defaults.set(mode.rawValue, forKey: Self.transportModeDefaultsKey)
        restartIfNeeded()
    }

    func updateEndpoints(
        tailnetHost: String?,
        tailnetPort: UInt16?,
        funnelURL: String?,
        cloudflareURL: String?
    ) throws {
        guard var current = credentials else { return }
        let trimmedHost = tailnetHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        current.tailnetHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        current.tailnetPort = (tailnetPort ?? 0) > 0 ? tailnetPort : nil
        current.funnelURL = MobileLink.normalizedWebSocketURL(funnelURL)
        current.cloudflareURL = MobileLink.normalizedWebSocketURL(cloudflareURL)
        try current.save()
        credentials = current
        restartIfNeeded()
    }

    private func restartIfNeeded() {
        guard credentials != nil, loop != nil else { return }
        stop()
        start()
    }

    // MARK: - Configuration

    /// Applies a configuration that the Mac pushed with `config_apply`.
    /// Returns the revision this phone holds afterwards, which the Mac shows.
    func applyConfiguration(_ configuration: MobileConfiguration) -> MobileConfigApplyResponse {
        guard let current = credentials else {
            return MobileConfigApplyResponse(revision: 0, applied: false)
        }
        guard let updated = current.applying(configuration) else {
            return MobileConfigApplyResponse(revision: current.configuration?.revision ?? 0, applied: false)
        }
        do {
            try updated.save()
        } catch {
            log.error("Couldn't save the Mac's configuration: \(error.localizedDescription, privacy: .public)")
            return MobileConfigApplyResponse(revision: current.configuration?.revision ?? 0, applied: false)
        }
        credentials = updated
        return MobileConfigApplyResponse(revision: configuration.revision, applied: true)
    }

    /// Reconnects so the Mac sends its configuration again, and waits for the result.
    /// Returns an error message, or nil when the phone connected.
    func refreshConfiguration(limit: Duration = .seconds(10)) async -> String? {
        guard credentials != nil else { return "This device isn't paired with a Mac." }
        stop()
        start()
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if phase == .connected { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if case .failed(let message) = phase { return message }
        return "The Mac didn't answer. The phone keeps the configuration it has."
    }

    // MARK: - Connection

    /// The one dial in flight. The foreground loop, a background flush, and a refresh
    /// all join it instead of dialing their own, because the Mac treats two connections
    /// from one device as a conflict and the extra dial only delays the first.
    private var dialTask: Task<Void, Error>?
    /// Serves the Mac's calls on the current channel, until the channel closes.
    private var serveTask: Task<Void, Error>?
    private var connectionID = UUID()
    @Published private(set) var lastConnected: Date?
    @Published private(set) var isRefreshing = false

    /// Whether the phone holds a connection to the Mac right now.
    var isConnected: Bool { channel != nil }

    /// Connects and reconnects until `stop()`.
    /// When the loop is already running but waiting out a backoff, it retries now.
    func start() {
        guard credentials != nil else { return }
        if loop != nil {
            reconnectNow()
            return
        }
        loop = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled, let self, self.credentials != nil {
                do {
                    try await self.ensureConnected(total: .seconds(30))
                    delay = .seconds(1)
                    try await self.serveTask?.value
                } catch {
                    if Task.isCancelled { break }
                    self.phase = .failed(error.localizedDescription)
                    self.log.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                }
                await self.refreshQueue()
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(10))
                if self.credentials != nil, self.channel == nil { self.phase = .searching }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        dialTask?.cancel()
        dialTask = nil
        serveTask?.cancel()
        serveTask = nil
        activeTransport = nil
        let channel = self.channel
        self.channel = nil
        connectionID = UUID()
        Task { await channel?.disconnect() }
    }

    /// Returns once a channel is open, joining a dial that is already running.
    private func ensureConnected(total: Duration) async throws {
        if channel != nil { return }
        if let dialTask { return try await dialTask.value }
        guard let credentials else { throw MobileError("This device isn't paired with a Mac.") }
        phase = .searching
        let task = Task { try await self.establish(credentials, total: total) }
        dialTask = task
        defer { if dialTask == task { dialTask = nil } }
        try await task.value
    }

    private func establish(_ credentials: PhoneCredentials, total: Duration) async throws {
        let result = try await dial(
            credentials.candidates(for: transportMode),
            mode: transportMode,
            device: credentials.device,
            key: SymmetricKey(data: credentials.key),
            total: total
        )
        try Task.checkCancellation()
        let updated = credentials.updating(from: result.welcome)
        if updated != credentials {
            try? updated.save()
            self.credentials = updated
        }
        adopt(result.channel, transport: result.transport)
    }

    /// Makes `channel` the connection and serves the Mac's calls on it until it closes.
    private func adopt(_ channel: any MobileTransportChannel, transport: MobileTransportMode) {
        let id = UUID()
        connectionID = id
        self.channel = channel
        activeTransport = transport
        lastConnected = Date()
        phase = .connected
        let tools = PhoneBackend.shared.tools
        let version = self.version
        serveTask = Task { [weak self] in
            do {
                try await MobilePeer.serve(channel, tools: tools, version: version)
                self?.connectionEnded(id)
            } catch {
                self?.connectionEnded(id)
                throw error
            }
        }
    }

    private func connectionEnded(_ id: UUID) {
        guard connectionID == id else { return }
        channel = nil
        activeTransport = nil
        if credentials != nil, phase == .connected { phase = .searching }
    }

    /// Retries now instead of waiting out the backoff.
    private func reconnectNow() {
        guard credentials != nil, channel == nil, dialTask == nil else { return }
        loop?.cancel()
        loop = nil
        start()
    }

    func refreshQueue() async {
        queuedBatches = await PhoneBackend.shared.pendingBatches
    }

    /// Pull to refresh: collects changes, reuses the open connection (or retries the
    /// dial now), and returns within `limit` whatever the Mac or HealthKit is doing,
    /// leaving the status on screen to say what happened.
    func refresh(limit: Duration = .seconds(8)) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        reconnectNow()
        var collected = false
        Task { @MainActor in
            await PhoneBackend.shared.syncAll()
            collected = true
        }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            let queued = await PhoneBackend.shared.pendingBatches
            queuedBatches = queued
            if collected, channel != nil, queued == 0 { break }
            if collected, channel == nil, case .failed = phase { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await refreshQueue()
    }

    // MARK: - Background

    private var flushing: Task<Bool, Never>?

    /// Connects long enough for the Mac to pull queued changes.
    /// Returns whether the queue emptied before `timeout`.
    /// Calls that arrive during a flush share it rather than dialing again.
    @discardableResult
    func flush(timeout: Duration = .seconds(20)) async -> Bool {
        if let flushing { return await flushing.value }
        let task = Task { await performFlush(timeout: timeout) }
        flushing = task
        let flushed = await task.value
        flushing = nil
        return flushed
    }

    private func performFlush(timeout: Duration) async -> Bool {
        guard credentials != nil else { return false }
        if await PhoneBackend.shared.pendingBatches == 0 { return true }
        // Whoever holds the connection (the foreground loop, or this flush) serves the Mac's pulls.
        let owned = channel == nil && loop == nil
        do {
            try await ensureConnected(total: .seconds(12))
        } catch {
            log.error("Background sync couldn't reach the Mac: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let emptied = await waitForEmptyQueue(timeout: timeout)
        if owned, loop == nil {
            // A flush that opened the connection closes it; a foreground loop keeps its own.
            stop()
        }
        await refreshQueue()
        return emptied
    }

    private func waitForEmptyQueue(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if await PhoneBackend.shared.pendingBatches == 0 { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    // MARK: - Pairing

    /// Pairs with the Mac that shows `code`, then keeps serving on that connection.
    func pair(_ code: MobilePairingCode) async throws {
        stop()
        let device = credentials?.device ?? UUID().uuidString
        let candidates = transportMode.candidates(for: code)
        let result = try await dial(
            candidates,
            mode: transportMode,
            pairing: code,
            device: device,
            key: nil
        )
        let channel = result.channel
        guard let key = result.deviceKey else {
            await channel.disconnect()
            throw MobileError("Pairing didn't produce a device key. Show a new code and try again.")
        }
        let credentials = PhoneCredentials(
            device: device,
            key: key.withUnsafeBytes { Data($0) },
            service: code.service,
            tailnetHost: code.tailnetHost,
            tailnetPort: code.tailnetPort,
            funnelURL: code.funnelURL,
            cloudflareURL: code.cloudflareURL,
            configuration: nil
        ).updating(from: result.welcome)
        try credentials.save()
        MobileAppGroup.defaults.removeObject(forKey: DevBootstrap.iosUnpairedDefaultsKey)
        // A new Mac has a new cache, which resets the outbox on its first pull.
        self.credentials = credentials
        adopt(channel, transport: result.transport)
        loop = Task { [weak self] in
            try? await self?.serveTask?.value
            guard let self else { return }
            self.loop = nil
            self.start()
        }
    }

    /// Forgets the Mac, asks it to forget this phone if it's reachable,
    /// and clears queued changes.
    func unpair() async {
        let credentials = self.credentials
        stop()
        if let credentials {
            let candidates = credentials.candidates(for: transportMode)
            // The Mac forgets the device when it can verify the request; if it's away,
            // the user can remove the phone in iMCP Settings.
            if let result = try? await dial(
                candidates,
                mode: transportMode,
                device: credentials.device,
                key: SymmetricKey(data: credentials.key),
                revoke: true,
                timeout: .seconds(5)
            ) {
                await result.channel.disconnect()
            }
        }
        PhoneCredentials.delete()
        MobileAppGroup.defaults.set(true, forKey: DevBootstrap.iosUnpairedDefaultsKey)
        try? await PhoneBackend.shared.openOutbox().deleteAll()
        PhoneActivityStore.shared.reset()
        self.credentials = nil
        self.activeTransport = nil
        phase = .unpaired
        await refreshQueue()
    }

    // MARK: - Multi-Transport Dialer

    private struct DialResult {
        var channel: any MobileTransportChannel
        var transport: MobileTransportMode
        var welcome: MobileWelcome
        var deviceKey: SymmetricKey?
    }

    private func dial(
        _ candidates: [MobileTransportCandidate],
        mode: MobileTransportMode,
        pairing: MobilePairingCode? = nil,
        device: String,
        key: SymmetricKey?,
        revoke: Bool = false,
        timeout: Duration = .seconds(15),
        total: Duration? = nil
    ) async throws -> DialResult {
        guard !candidates.isEmpty else {
            throw MobileError(
                "No endpoint is configured for \(mode.shortLabel). Configure it in Connection Settings or pair again."
            )
        }
        var lastError: Error?
        let deadline = total.map { ContinuousClock.now.advanced(by: $0) }
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let isLast = index == candidates.count - 1
            var candidateTimeout: Duration =
                (!isLast && candidate.mode == .localOnly) ? min(timeout, .seconds(5)) : timeout
            if let deadline {
                // The whole dial has a budget, so a dead first path can't use it all.
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining < .seconds(1) { break }
                candidateTimeout = min(candidateTimeout, remaining)
            }
            do {
                switch candidate {
                case .bonjour(let service):
                    let endpoint = NWEndpoint.service(
                        name: service,
                        type: MobileLink.serviceType,
                        domain: "local.",
                        interface: nil
                    )
                    do {
                        let session = try await connectNW(
                            endpoint: endpoint,
                            pairing: pairing,
                            device: device,
                            key: key,
                            revoke: revoke,
                            timeout: candidateTimeout
                        )
                        return DialResult(
                            channel: session.channel,
                            transport: .localOnly,
                            welcome: session.welcome,
                            deviceKey: session.deviceKey
                        )
                    } catch {
                        guard pairing == nil else { throw error }
                        let discovered = await discoverBonjourEndpoints(excludingService: service, timeout: .seconds(3))
                        for altEndpoint in discovered {
                            if Task.isCancelled { throw CancellationError() }
                            if let session = try? await connectNW(
                                endpoint: altEndpoint,
                                pairing: nil,
                                device: device,
                                key: key,
                                revoke: revoke,
                                timeout: min(candidateTimeout, .seconds(5))
                            ) {
                                return DialResult(
                                    channel: session.channel,
                                    transport: .localOnly,
                                    welcome: session.welcome,
                                    deviceKey: session.deviceKey
                                )
                            }
                        }
                        throw error
                    }

                case .tailscaleVPN(let host, let port):
                    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                        throw MobileError("Invalid Tailscale port \(port).")
                    }
                    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
                    do {
                        let session = try await connectNW(
                            endpoint: endpoint,
                            pairing: pairing,
                            device: device,
                            key: key,
                            revoke: revoke,
                            timeout: candidateTimeout
                        )
                        return DialResult(
                            channel: session.channel,
                            transport: .tailscaleVPN,
                            welcome: session.welcome,
                            deviceKey: session.deviceKey
                        )
                    } catch {
                        // The bootstrap's address is a fallback for a phone that hasn't learned the Mac's configuration.
                        if credentials?.configuration == nil,
                            let fallbackIP = DevBootstrap.tailnetIP,
                            host == DevBootstrap.tailnetHost,
                            fallbackIP != host
                        {
                            let ipEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(fallbackIP), port: nwPort)
                            let session = try await connectNW(
                                endpoint: ipEndpoint,
                                pairing: pairing,
                                device: device,
                                key: key,
                                revoke: revoke,
                                timeout: candidateTimeout
                            )
                            return DialResult(
                                channel: session.channel,
                                transport: .tailscaleVPN,
                                welcome: session.welcome,
                                deviceKey: session.deviceKey
                            )
                        }
                        throw error
                    }

                case .tailscaleFunnel(let url), .cloudflare(let url):
                    let creds: MobileDialer.Credentials
                    if let pairing {
                        creds = MobileWebSocketDialer.pairing(pairing, device: device, name: Self.deviceName)
                    } else if let key {
                        creds = MobileWebSocketDialer.paired(
                            device: device,
                            name: Self.deviceName,
                            key: key,
                            revoke: revoke
                        )
                    } else {
                        throw MobileError("Missing device credentials.")
                    }
                    let session = try await MobileWebSocketDialer.connect(
                        to: url,
                        with: creds,
                        timeout: candidateTimeout
                    )
                    return DialResult(
                        channel: session.channel,
                        transport: candidate.mode,
                        welcome: session.welcome,
                        deviceKey: session.deviceKey
                    )
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MobileError("Couldn't reach the Mac.")
    }

    private func connectNW(
        endpoint: NWEndpoint,
        pairing: MobilePairingCode?,
        device: String,
        key: SymmetricKey?,
        revoke: Bool,
        timeout: Duration
    ) async throws -> MobileDialer.Session {
        let creds: MobileDialer.Credentials
        if let pairing {
            creds = MobileDialer.pairing(pairing, device: device, name: Self.deviceName)
        } else if let key {
            creds = MobileDialer.paired(device: device, name: Self.deviceName, key: key, revoke: revoke)
        } else {
            throw MobileError("Missing device credentials.")
        }
        return try await MobileDialer.connect(to: endpoint, with: creds, timeout: timeout)
    }

    /// Browses `_imcp-mobile._tcp` on `local.` to find a paired Mac whose Bonjour name differs from `excludingService`.
    private func discoverBonjourEndpoints(excludingService: String, timeout: Duration) async -> [NWEndpoint] {
        let descriptor = NWBrowser.Descriptor.bonjour(type: MobileLink.serviceType, domain: "local.")
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: descriptor, using: parameters)
        final class EndpointCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [NWEndpoint] = []

            func append(_ endpoints: [NWEndpoint]) {
                lock.withLock {
                    for endpoint in endpoints where !seen.contains(endpoint) {
                        seen.append(endpoint)
                    }
                }
            }

            func all() -> [NWEndpoint] {
                lock.withLock { seen }
            }
        }
        let collector = EndpointCollector()
        browser.browseResultsChangedHandler = { results, _ in
            let endpoints = results.compactMap { result -> NWEndpoint? in
                if case .service(let name, _, _, _) = result.endpoint, name == excludingService {
                    return nil
                }
                return result.endpoint
            }
            collector.append(endpoints)
        }
        browser.start(queue: .global())
        try? await Task.sleep(for: timeout)
        browser.cancel()
        return collector.all()
    }
}
