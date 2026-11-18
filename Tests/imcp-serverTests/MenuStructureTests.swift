import XCTest

/// The menu bar menu is a native menu, so these check which items it has and how they group.
final class MenuStructureTests: XCTestCase {
    private let services = [
        MenuServiceItem(id: "A", name: "Calendar", symbol: "calendar", isOn: true),
        MenuServiceItem(id: "B", name: "Mail", symbol: "envelope.fill", isOn: false),
    ]

    func testGroupsAreServerServicesClientsAppAndQuit() {
        let sections = MenuStructure.make(isServerEnabled: true, services: services, status: [])
        XCTAssertEqual(sections.count, 5)
        XCTAssertEqual(sections[0], .server(isOn: true, status: []))
        XCTAssertEqual(sections[1], .services(items: services, isEnabled: true))
        XCTAssertEqual(
            sections[2],
            .actions([.setUp, .configureClaudeDesktop, .configureClaudeCode, .copyServerCommand])
        )
        XCTAssertEqual(sections[3], .actions([.settings, .checkForUpdates, .about]))
        XCTAssertEqual(sections[4], .actions([.quit]))
    }

    func testServicesAreDisabledAndStatusHiddenWhileServerIsOff() {
        let sections = MenuStructure.make(
            isServerEnabled: false,
            services: services,
            status: ["Remote access: Tailscale Funnel"]
        )
        XCTAssertEqual(sections[0], .server(isOn: false, status: []))
        XCTAssertEqual(sections[1], .services(items: services, isEnabled: false))
    }

    func testStatusLinesAppearUnderTheServerSwitch() {
        let sections = MenuStructure.make(
            isServerEnabled: true,
            services: services,
            status: ["Remote access: Tailscale Funnel"]
        )
        XCTAssertEqual(sections[0], .server(isOn: true, status: ["Remote access: Tailscale Funnel"]))
    }

    func testEveryActionAppearsOnceAndHasATitle() {
        let sections = MenuStructure.make(isServerEnabled: true, services: services, status: [])
        let actions = sections.flatMap { section -> [MenuAction] in
            if case .actions(let actions) = section { return actions }
            return []
        }
        XCTAssertEqual(Set(actions), Set(MenuAction.allCases))
        XCTAssertEqual(actions.count, MenuAction.allCases.count)
        XCTAssertTrue(MenuAction.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
