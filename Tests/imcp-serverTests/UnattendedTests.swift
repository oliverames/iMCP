import Foundation
import MCP
import XCTest

/// Tests for the Unattended setting and the tool call path.
///
/// With Unattended on, iMCP approves its own confirmations without showing a window.
/// Per-service Allow writes switches stay authoritative either way,
/// and no per-call confirmation exists anymore.
final class UnattendedTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "imcp-unattended-tests-\(UUID().uuidString)"
        defaults = TestDefaults.suite(named: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Model & Persistence

    func testDefaultsToOffAndPersistsSelection() {
        // A new install shows confirmation windows until the person turns this on.
        XCTAssertFalse(Unattended.isEnabled(defaults: defaults))

        for enabled in [false, true] {
            Unattended.setEnabled(enabled, defaults: defaults)
            XCTAssertEqual(Unattended.isEnabled(defaults: defaults), enabled)
        }
    }

    func testReplacedApprovalModesDecideTheDefaultUntilTheSettingIsChosen() {
        // The modes that asked in iMCP keep asking after the update.
        defaults.set("askWritesOnly", forKey: Unattended.legacyDefaultsKey)
        XCTAssertFalse(Unattended.isEnabled(defaults: defaults))
        defaults.set("askEverything", forKey: Unattended.legacyDefaultsKey)
        XCTAssertFalse(Unattended.isEnabled(defaults: defaults))

        // The full-access modes never showed iMCP windows, so they stay popup-free.
        defaults.set("agentManaged", forKey: Unattended.legacyDefaultsKey)
        XCTAssertTrue(Unattended.isEnabled(defaults: defaults))
        defaults.set("allowEverything", forKey: Unattended.legacyDefaultsKey)
        XCTAssertTrue(Unattended.isEnabled(defaults: defaults))

        // An unknown or missing legacy value behaves like a fresh install.
        defaults.set("unexpectedMode", forKey: Unattended.legacyDefaultsKey)
        XCTAssertFalse(Unattended.isEnabled(defaults: defaults))

        // Once the person chooses, the legacy value no longer matters.
        defaults.set("askEverything", forKey: Unattended.legacyDefaultsKey)
        Unattended.setEnabled(true, defaults: defaults)
        XCTAssertTrue(Unattended.isEnabled(defaults: defaults))
        XCTAssertNil(defaults.string(forKey: Unattended.legacyDefaultsKey))
    }

    // MARK: - Outbound Confirmations

    func testMacConfirmerApprovesWithoutAWindowWhileUnattended() async {
        Unattended.setEnabled(true, defaults: defaults)
        let confirmer = MacOutboundConfirmer(defaultsSuiteName: suiteName)
        let answer = await confirmer.confirm(
            OutboundConfirmationRequest(action: "Send Message", clientName: "Duet", details: [])
        )
        XCTAssertEqual(answer, .approved)
    }

    // MARK: - Tool Calls

    func testExecuteRunsReadsAndWritesWithoutAnyPrompt() async throws {
        Unattended.setEnabled(true, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: true)
        let readResult = try await ToolCallApproval.execute(
            tool: service.tool(named: "fake_read"),
            in: service,
            arguments: [:],
            clientName: "Duet",
            defaults: defaults
        )
        let writeResult = try await ToolCallApproval.execute(
            tool: service.tool(named: "fake_write"),
            in: service,
            arguments: [:],
            clientName: "Duet",
            defaults: defaults
        )
        XCTAssertEqual(readResult, "read-ok")
        XCTAssertEqual(writeResult, "write-ok")
        XCTAssertEqual(service.writeCounter.value, 1)
    }

    func testWritesDisabledInServiceSettingsRejectBeforeRunning() async {
        Unattended.setEnabled(true, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: false)
        ServiceWrites.setEnabled(false, serviceID: service.serviceID, defaults: defaults)

        XCTAssertFalse(service.areWritesEnabled(defaults: defaults))
        XCTAssertEqual(
            Set(service.listedTools(defaults: defaults).map(\.name)),
            ["fake_read"]
        )

        do {
            _ = try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_write"),
                in: service,
                arguments: [:],
                clientName: "Claude Desktop",
                defaults: defaults
            )
            XCTFail("Expected WritesDisabledError")
        } catch {
            XCTAssertEqual(error as? WritesDisabledError, WritesDisabledError(tool: "fake_write"))
            XCTAssertEqual(service.writeCounter.value, 0)
        }
    }

    // MARK: - Test Doubles

    private final class FakeService: Service, @unchecked Sendable {
        let writesEnabledByDefault: Bool
        let readCounter = Counter()
        let writeCounter = Counter()

        init(writesEnabledByDefault: Bool = true) {
            self.writesEnabledByDefault = writesEnabledByDefault
        }

        var tools: [Tool] {
            Tool(
                name: "fake_read",
                description: "Read test data.",
                inputSchema: .object(properties: ["query": .string()], additionalProperties: false),
                annotations: .init(title: "Fetch Fake Data", readOnlyHint: true, openWorldHint: false)
            ) { _ in
                self.readCounter.increment()
                return "read-ok"
            }
            Tool(
                name: "fake_write",
                description: "Write test data.",
                inputSchema: .object(properties: ["value": .string()], additionalProperties: false),
                annotations: .init(title: "Update Fake Data", readOnlyHint: false, destructiveHint: true)
            ) { _ in
                self.writeCounter.increment()
                return "write-ok"
            }
        }

        func tool(named name: String) -> Tool {
            tools.first { $0.name == name }!
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func increment() { lock.withLock { count += 1 } }
    }
}
