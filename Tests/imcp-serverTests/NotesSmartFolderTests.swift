import Foundation
import TopoText
import XCTest

final class NotesSmartFolderTests: XCTestCase {
    func testSmartFolderQueryStripsTheDeletedClause() {
        let query = SmartFolderQuery(#"{"entity":"note","type":{"and":[{"deleted":false},{"pinned":true}]}}"#)
        XCTAssertEqual(query.rules, ["pinned": true])
        XCTAssertEqual(query.includesRecentlyDeleted, false)
    }

    func testSmartFolderQueryKeepsSeveralRulesTogether() {
        let query = SmartFolderQuery(#"{"type":{"and":[{"deleted":true},{"tag":"A"},{"attachment":true}]}}"#)
        XCTAssertEqual(query.rules, ["and": [["tag": "A"], ["attachment": true]]])
        XCTAssertEqual(query.includesRecentlyDeleted, true)
    }

    func testSmartFolderQueryKeepsWhatItDoesNotKnow() {
        XCTAssertEqual(SmartFolderQuery(#"{"tags":["groceries"]}"#).rules, ["tags": ["groceries"]])
        XCTAssertEqual(SmartFolderQuery(#"{"type":{"or":[{"pinned":true}]}}"#).rules, ["or": [["pinned": true]]])
        XCTAssertNil(SmartFolderQuery("not json").rules)
        XCTAssertNil(SmartFolderQuery("not json").includesRecentlyDeleted)
    }

    func testSmartFolderValueHasRulesParentAndStoredQuery() {
        let parent = TopoText.Folder.ID("P")!
        let text = #"{"type":{"and":[{"deleted":false},{"pinned":true}]}}"#
        let folder = TopoText.SmartFolder(
            id: TopoText.SmartFolder.ID("S")!,
            name: "Pinned",
            parentID: parent,
            query: text
        )
        let object = smartFolderValue(folder, folderNames: [parent: "Recipes"]).objectValue
        XCTAssertEqual(object?["@id"], "S")
        XCTAssertEqual(object?["name"], "Pinned")
        XCTAssertNil(object?["account"])
        XCTAssertEqual(object?["parentFolder"], ["@id": "P", "name": "Recipes"])
        XCTAssertEqual(object?["rules"], ["pinned": true])
        XCTAssertEqual(object?["query"], .string(text))
        XCTAssertNil(object?["includesRecentlyDeleted"])
    }
}
