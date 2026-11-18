import XCTest

final class SettingsCatalogTests: XCTestCase {
    func testEveryTabHasSettings() {
        for tab in SettingsPane.tabs {
            XCTAssertFalse(SettingsItem.items(in: tab).isEmpty, "\(tab.title) has no settings")
        }
    }

    func testSettingsLiveWhereAPersonWouldLookForThem() {
        XCTAssertEqual(SettingsItem.approvalMode.tab, .general)
        XCTAssertEqual(SettingsItem.trustedApps.tab, .clients)
        XCTAssertEqual(SettingsItem.connectedCloudApps.tab, .clients)
        XCTAssertEqual(SettingsItem.routeList.tab, .mobile)
        XCTAssertEqual(SettingsItem.accessChoice.tab, .remoteAccess)
        XCTAssertEqual(SettingsItem.accessTokens.tab, .advanced)
        XCTAssertEqual(SettingsItem.mobileOverrides.tab, .advanced)
        XCTAssertEqual(SettingsItem.serverCommand.tab, .advanced)
        XCTAssertEqual(SettingsItem.cachedData.tab, .advanced)
    }

    /// Settings stores the raw value to reopen to the same tab, so these must not change.
    func testStoredTabValuesAreStable() {
        XCTAssertEqual(SettingsPane.general.rawValue, "general")
        XCTAssertEqual(SettingsPane.clients.rawValue, "clients")
        XCTAssertEqual(SettingsPane.mobile.rawValue, "mobile")
        XCTAssertEqual(SettingsPane.remoteAccess.rawValue, "remoteAccess")
        XCTAssertEqual(SettingsPane.advanced.rawValue, "advanced")
    }

    /// A stored service id reopens to that service's pane.
    func testStoredServiceIDsReopenToTheService() {
        XCTAssertEqual(SettingsPane(rawValue: "CalendarService"), .service("CalendarService"))
        XCTAssertEqual(SettingsPane.service("NotesService").rawValue, "NotesService")
    }

    func testKnownClientsAreMatchedByTheNameTheyReport() {
        XCTAssertEqual(KnownClient.match(name: "Claude Desktop"), .claudeDesktop)
        XCTAssertEqual(KnownClient.match(name: "claude-code"), .claudeCode)
        XCTAssertEqual(KnownClient.match(name: "Claude Code (CLI)"), .claudeCode)
        XCTAssertEqual(KnownClient.match(name: "Claude Duet"), .claudeDuet)
        XCTAssertEqual(KnownClient.match(name: "Claude"), .claudeAI)
        XCTAssertEqual(KnownClient.match(name: "Muse"), .muse)
        XCTAssertEqual(KnownClient.match(name: "Gemini CLI"), .gemini)
        XCTAssertNil(KnownClient.match(name: "Some Other Tool"))
    }

    func testStoreLogosExistForTheFourAppsAndClaudeCodeUsesASymbol() {
        XCTAssertEqual(KnownClient.claudeDesktop.logoAsset, "ConnectorClaude")
        XCTAssertEqual(KnownClient.claudeDuet.logoAsset, "ConnectorClaudeDuet")
        XCTAssertEqual(KnownClient.muse.logoAsset, "ConnectorMuse")
        XCTAssertEqual(KnownClient.gemini.logoAsset, "ConnectorGemini")
        XCTAssertNil(KnownClient.claudeCode.logoAsset)
        XCTAssertEqual(KnownClient.claudeCode.symbol, "terminal")
    }

    func testEveryApprovalModeHasAShortCaption() {
        for mode in ApprovalMode.allCases {
            XCTAssertFalse(mode.settingsCaption.isEmpty)
            XCTAssertLessThanOrEqual(mode.settingsCaption.count, 60)
        }
    }
}
