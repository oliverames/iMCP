import Foundation
import MCP
import SQLite3
import XCTest
import os

/// A mapper that knows the pairs it is given, for tests of the tools. It reads no database.
struct FakeNotesIDMapper: NotesIDMapping {
    /// UUID by scripting id.
    var uuidByScriptID: [String: String] = [:]
    var failure: NotesIDMapperError?

    func scriptIDs(forUUIDs uuids: [String], kind: NotesIDKind) async throws -> [String: String] {
        if let failure { throw failure }
        let wanted = Set(uuids.map { $0.uppercased() })
        var found: [String: String] = [:]
        for (script, uuid) in uuidByScriptID where NotesScriptID(script)?.kind == kind {
            if wanted.contains(uuid.uppercased()) { found[uuid.uppercased()] = script }
        }
        return found
    }

    func uuids(forScriptIDs ids: [String]) async throws -> [String: String] {
        if let failure { throw failure }
        return uuidByScriptID.filter { ids.contains($0.key) }
    }
}

/// Answers nothing until it has been asked `afterAsks` times, as a database that lags behind Notes does.
final class LaggingNotesIDMapper: NotesIDMapping, @unchecked Sendable {
    private let asked = OSAllocatedUnfairLock(initialState: 0)
    let afterAsks: Int
    let pairs: [String: String]

    init(afterAsks: Int, pairs: [String: String]) {
        self.afterAsks = afterAsks
        self.pairs = pairs
    }

    var askCount: Int { asked.withLock { $0 } }

    func scriptIDs(forUUIDs uuids: [String], kind: NotesIDKind) async throws -> [String: String] { [:] }

    func uuids(forScriptIDs ids: [String]) async throws -> [String: String] {
        let count = asked.withLock { value -> Int in
            value += 1
            return value
        }
        return count > afterAsks ? pairs.filter { ids.contains($0.key) } : [:]
    }
}

/// These tests read no real Notes data: the database is a small file made here.
final class NotesIDMapperTests: XCTestCase {
    private let store = "7B1F0C52-9E3A-4D6B-8A21-5C4E0F9D3B18"
    private let noteUUID = "0F3A7C54-5B1E-4D0B-9C57-2E8D1A6B4F10"
    private let otherNoteUUID = "6C2E9D18-3F7A-4B50-A1D4-8E0B5F2C7A93"
    private let sameKeyNoteUUID = "C4D81A6F-2B09-4E73-9F15-0A7E3B6D8C21"
    private let folderUUID = "9B2E6D31-7A44-4C8F-8E0D-3C5A1F7B2D90"
    private let attachmentUUID = "E1A5F3B7-0C28-4D96-B4E2-6A9D1C7F3085"

    // MARK: - Script ids

    func testScriptIDsAreParsedAndFormatted() throws {
        let note = try XCTUnwrap(NotesScriptID("x-coredata://\(store)/ICNote/p7"))
        XCTAssertEqual(note, NotesScriptID(storeUUID: store, kind: .note, primaryKey: 7))
        XCTAssertEqual(note.description, "x-coredata://\(store)/ICNote/p7")
        let folder = try XCTUnwrap(NotesScriptID("x-coredata://\(store)/ICFolder/p31"))
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.primaryKey, 31)
        XCTAssertEqual(NotesScriptID(storeUUID: store, kind: .folder, primaryKey: 31).description, folder.description)
    }

    func testOtherTextIsNotAScriptID() {
        for text in [
            "", "12", noteUUID, "x-coredata://", "x-coredata://\(store)", "x-coredata://\(store)/ICNote",
            "x-coredata://\(store)/ICNote/7", "x-coredata://\(store)/ICNote/p", "x-coredata://\(store)/ICNote/p1x",
            "x-coredata://\(store)/ICNote/p-1", "x-coredata://\(store)/ICAccount/p1",
            "x-coredata://\(store)/ICNote/p7/extra", "x-coredata:///ICNote/p7", "x-coredata://a\nb/ICNote/p7",
            "x-coredata://\(store)/ICNote/p99999999999999999999",
        ] {
            XCTAssertNil(NotesScriptID(text), text)
        }
    }

    func testReferencesAreUUIDsOrScriptIDsAndNothingElse() throws {
        let script = "x-coredata://\(store)/ICNote/p7"
        XCTAssertEqual(try NotesReference.parse(" \(script) ", label: "id", kind: .note), .script(script))
        XCTAssertEqual(
            try NotesReference.parse(noteUUID.lowercased(), label: "id", kind: .note),
            .uuid(noteUUID)
        )
        for text in ["12", "", "x-coredata://a\nb", "not-a-uuid", String(repeating: "x-coredata://", count: 50)] {
            XCTAssertThrowsError(try NotesReference.parse(text, label: "id", kind: .note), text)
        }
    }

    // MARK: - The database

    /// A database with the tables and columns that the Notes database has, and a few rows.
    private func makeDatabase(
        storeUUID: String? = nil,
        withNoteTable: Bool = true,
        in folder: URL
    ) throws -> URL {
        let url = folder.appendingPathComponent(NotesIDTable.databaseFileName)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statements = [
            "CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB)",
            "INSERT INTO Z_METADATA (Z_VERSION, Z_UUID) VALUES (1, '\(storeUUID ?? store)')",
            "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER)",
            "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME) VALUES (4, 'ICAttachment'), (11, 'ICFolder'), (12, 'ICNote')",
        ]
        if withNoteTable {
            statements += [
                "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER VARCHAR, ZTITLE1 VARCHAR)",
                // Z_PK is the table's key, so no two rows share one; the entity says what a row is.
                "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER) VALUES (7, 12, '\(noteUUID)')",
                "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER) VALUES (8, 12, '\(otherNoteUUID)')",
                "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER) VALUES (3, 12, '\(sameKeyNoteUUID)')",
                "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER) VALUES (4, 11, '\(folderUUID)')",
                "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER) VALUES (9, 4, '\(attachmentUUID)')",
                "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER) VALUES (10, 11, 'TrashFolder-LocalAccount')",
            ]
        }
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(connection, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        return url
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("imcp-ids-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testScriptIDsComeFromTheRowKeyAndTheStoreUUID() throws {
        let url = try makeDatabase(in: try makeFolder())
        let notes = try NotesIDTable.scriptIDs(
            databaseAt: url,
            uuids: [noteUUID, otherNoteUUID, sameKeyNoteUUID, "00000000-0000-0000-0000-000000000000"],
            kind: .note
        )
        XCTAssertEqual(
            notes,
            [
                noteUUID: "x-coredata://\(store)/ICNote/p7",
                otherNoteUUID: "x-coredata://\(store)/ICNote/p8",
                sameKeyNoteUUID: "x-coredata://\(store)/ICNote/p3",
            ]
        )
        let folders = try NotesIDTable.scriptIDs(
            databaseAt: url,
            uuids: [folderUUID, "TRASHFOLDER-LOCALACCOUNT"],
            kind: .folder
        )
        XCTAssertEqual(
            folders,
            [
                folderUUID: "x-coredata://\(store)/ICFolder/p4",
                "TRASHFOLDER-LOCALACCOUNT": "x-coredata://\(store)/ICFolder/p10",
            ]
        )
    }

    func testAUUIDOfOneKindIsNotFoundAsAnother() throws {
        let url = try makeDatabase(in: try makeFolder())
        XCTAssertEqual(try NotesIDTable.scriptIDs(databaseAt: url, uuids: [noteUUID], kind: .folder), [:])
        XCTAssertEqual(try NotesIDTable.scriptIDs(databaseAt: url, uuids: [folderUUID], kind: .note), [:])
        // An attachment has a row in the same table, and no scripting id of this form.
        XCTAssertEqual(try NotesIDTable.scriptIDs(databaseAt: url, uuids: [attachmentUUID], kind: .note), [:])
    }

    func testUUIDsComeFromTheEntityAndTheRowKey() throws {
        let url = try makeDatabase(in: try makeFolder())
        let note = "x-coredata://\(store)/ICNote/p3"
        let folder = "x-coredata://\(store)/ICFolder/p4"
        let ids = [
            "x-coredata://\(store)/ICNote/p7", note, folder, "x-coredata://\(store)/ICNote/p404",
            "x-coredata://\(store)/ICFolder/p10",
            // A key that belongs to a row of the other entity names nothing.
            "x-coredata://\(store)/ICFolder/p7", "x-coredata://\(store)/ICNote/p4",
        ]
        let parsed = Dictionary(uniqueKeysWithValues: ids.map { ($0, NotesScriptID($0)!) })
        XCTAssertEqual(
            try NotesIDTable.uuids(databaseAt: url, scriptIDs: parsed),
            [
                "x-coredata://\(store)/ICNote/p7": noteUUID,
                note: sameKeyNoteUUID,
                folder: folderUUID,
                "x-coredata://\(store)/ICFolder/p10": "TrashFolder-LocalAccount",
            ]
        )
    }

    func testAScriptIDFromAnotherDatabaseNamesNothing() throws {
        let url = try makeDatabase(in: try makeFolder())
        let foreign = "x-coredata://11111111-1111-1111-1111-111111111111/ICNote/p7"
        let ours = "x-coredata://\(store.lowercased())/ICNote/p7"
        XCTAssertEqual(
            try NotesIDTable.uuids(
                databaseAt: url,
                scriptIDs: [foreign: NotesScriptID(foreign)!, ours: NotesScriptID(ours)!]
            ),
            [ours: noteUUID]
        )
    }

    func testAnUnreadableDatabaseIsReportedNotGuessed() throws {
        let folder = try makeFolder()
        let missing = folder.appendingPathComponent("none.sqlite")
        XCTAssertThrowsError(try NotesIDTable.scriptIDs(databaseAt: missing, uuids: [noteUUID], kind: .note)) {
            XCTAssertTrue($0 is NotesIDMapperError, "\($0)")
        }
        let bare = try makeDatabase(withNoteTable: false, in: try makeFolder())
        XCTAssertThrowsError(try NotesIDTable.scriptIDs(databaseAt: bare, uuids: [noteUUID], kind: .note)) {
            XCTAssertTrue($0 is NotesIDMapperError, "\($0)")
        }
        let notADatabase = folder.appendingPathComponent("junk.sqlite")
        try Data("this is not sqlite".utf8).write(to: notADatabase)
        XCTAssertThrowsError(try NotesIDTable.scriptIDs(databaseAt: notADatabase, uuids: [noteUUID], kind: .note))
    }

    func testTheDatabaseMapperReadsThroughTheGrantedFolder() async throws {
        let folder = try makeFolder()
        _ = try makeDatabase(in: folder)
        let mapper = NotesDatabaseIDMapper { read in try read(folder) }
        let script = try await mapper.scriptIDs(forUUIDs: [noteUUID.lowercased(), folderUUID], kind: .note)
        XCTAssertEqual(script, [noteUUID: "x-coredata://\(store)/ICNote/p7"])
        let uuids = try await mapper.uuids(forScriptIDs: [
            "x-coredata://\(store)/ICNote/p8", "not an id", "x-coredata://\(store)/ICFolder/p4",
        ])
        XCTAssertEqual(
            uuids,
            ["x-coredata://\(store)/ICNote/p8": otherNoteUUID, "x-coredata://\(store)/ICFolder/p4": folderUUID]
        )
        // Nothing to translate means nothing to open.
        let none = NotesDatabaseIDMapper { _ in
            XCTFail("opened the database")
            return [:]
        }
        let empty = try await none.scriptIDs(forUUIDs: [], kind: .note)
        XCTAssertEqual(empty, [:])
        let notIDs = try await none.uuids(forScriptIDs: ["12"])
        XCTAssertEqual(notIDs, [:])
    }

    func testTheDatabaseIsOpenedReadOnly() throws {
        let folder = try makeFolder()
        let url = try makeDatabase(in: folder)
        let before = try Data(contentsOf: url)
        _ = try NotesIDTable.scriptIDs(databaseAt: url, uuids: [noteUUID], kind: .note)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-journal"))
    }

    // MARK: - Fallback and bridge

    func testTheBridgeIsAskedOnlyWhenTheDatabaseCantBeRead() async throws {
        let script = "x-coredata://\(store)/ICNote/p7"
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let bridge = NotesBridgeIDMapper(
            isAvailable: { true },
            lookup: { _ in
                calls.withLock { $0 += 1 }
                return (script, self.noteUUID)
            }
        )
        let working = FallbackNotesIDMapper(
            primary: FakeNotesIDMapper(uuidByScriptID: [script: noteUUID]),
            fallback: bridge
        )
        let primary = try await working.uuids(forScriptIDs: [script])
        XCTAssertEqual(primary, [script: noteUUID])
        XCTAssertEqual(calls.withLock { $0 }, 0)

        let broken = FallbackNotesIDMapper(
            primary: FakeNotesIDMapper(failure: .unavailable("database")),
            fallback: bridge
        )
        let fallbackUUIDs = try await broken.uuids(forScriptIDs: [script])
        XCTAssertEqual(fallbackUUIDs, [script: noteUUID])
        let fallbackScripts = try await broken.scriptIDs(forUUIDs: [noteUUID], kind: .note)
        XCTAssertEqual(fallbackScripts, [noteUUID: script])
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testTheBridgeCantMapFoldersOrRunWhilePrivateFeaturesAreOff() async throws {
        let off = NotesBridgeIDMapper(isAvailable: { false }, lookup: { _ in (nil, nil) })
        let primaryError = NotesIDMapperError.unavailable("database")
        let both = FallbackNotesIDMapper(primary: FakeNotesIDMapper(failure: primaryError), fallback: off)
        do {
            _ = try await both.uuids(forScriptIDs: ["x-coredata://\(store)/ICNote/p7"])
            XCTFail("translated without a source")
        } catch {
            // The database's reason is the one reported.
            XCTAssertEqual(error as? NotesIDMapperError, primaryError)
        }
        let on = NotesBridgeIDMapper(isAvailable: { true }, lookup: { _ in ("x", "y") })
        do {
            _ = try await on.scriptIDs(forUUIDs: [folderUUID], kind: .folder)
            XCTFail("the bridge mapped a folder")
        } catch {
            XCTAssertTrue(error is NotesIDMapperError)
        }
        let folderIDs = try await on.uuids(forScriptIDs: ["x-coredata://\(store)/ICFolder/p4"])
        XCTAssertEqual(folderIDs, [:])
    }

    // MARK: - Resolving and naming

    func testReferencesResolveToScriptIDsWithEachFailureOwn() async throws {
        let script = "x-coredata://\(store)/ICNote/p7"
        let mapper = FakeNotesIDMapper(uuidByScriptID: [script: noteUUID])
        let results = await mapper.resolve(
            [.script(script), .uuid(noteUUID), .uuid(otherNoteUUID)],
            kind: .note
        )
        XCTAssertEqual(try results[0].get(), NotesResolved(scriptID: script, uuid: nil))
        XCTAssertEqual(try results[1].get(), NotesResolved(scriptID: script, uuid: noteUUID))
        XCTAssertThrowsError(try results[2].get()) {
            XCTAssertTrue("\($0)".contains("no note has the UUID"), "\($0)")
        }

        let broken = FakeNotesIDMapper(failure: .unavailable("the database is locked"))
        let unreadable = await broken.resolve([.uuid(noteUUID), .script(script)], kind: .note)
        XCTAssertThrowsError(try unreadable[0].get()) {
            XCTAssertTrue("\($0)".contains("x-coredata://"), "\($0)")
            XCTAssertTrue("\($0)".contains("the database is locked"), "\($0)")
        }
        // A scripting id needs no translation, so it still works.
        XCTAssertEqual(try unreadable[1].get().scriptID, script)
    }

    func testResultsWaitForADatabaseThatLagsAndGiveUpWhenItIsUnreadable() async throws {
        let script = "x-coredata://\(store)/ICNote/p7"
        let lagging = LaggingNotesIDMapper(afterAsks: 2, pairs: [script: noteUUID])
        let found = await lagging.uuids(forResultIDs: [script], awaitingNew: true)
        XCTAssertEqual(found, [script: noteUUID])
        XCTAssertEqual(lagging.askCount, 3)

        let once = LaggingNotesIDMapper(afterAsks: 2, pairs: [script: noteUUID])
        let notYet = await once.uuids(forResultIDs: [script])
        XCTAssertEqual(notYet, [:])
        XCTAssertEqual(once.askCount, 1)

        let unreadable = FakeNotesIDMapper(failure: .unavailable("x"))
        let none = await unreadable.uuids(forResultIDs: [script], awaitingNew: true)
        XCTAssertEqual(none, [:])
        // Text that isn't a scripting id is never sent to the database.
        let silent = LaggingNotesIDMapper(afterAsks: 0, pairs: [:])
        _ = await silent.uuids(forResultIDs: ["12", "x-coredata://a\nb"], awaitingNew: true)
        XCTAssertEqual(silent.askCount, 0)
    }

    func testResultFieldsCarryTheUUIDOnlyWhenItIsKnown() {
        let script = "x-coredata://\(store)/ICNote/p7"
        XCTAssertEqual(
            NotesIdentifiers.fields(script, uuids: [script: noteUUID]),
            ["scriptIdentifier": .string(script), "identifier": .string(noteUUID)]
        )
        XCTAssertEqual(NotesIdentifiers.fields(script, uuids: [:]), ["scriptIdentifier": .string(script)])
        XCTAssertEqual(
            NotesIdentifiers.fields(script, uuids: [script: noteUUID], prefix: "folder"),
            ["folderScriptIdentifier": .string(script), "folderIdentifier": .string(noteUUID)]
        )
    }

    // MARK: - Read results

    func testReadResultsGainTheScriptIDOfEveryNoteAndFolderTheDatabaseKnows() {
        let script = "x-coredata://\(store)/ICNote/p7"
        let result: Value = [
            "itemListElement": [
                [
                    "@id": .string(noteUUID),
                    "isPartOf": ["@id": .string(folderUUID), "name": "Work"],
                    "linkedNotes": [["@id": .string(otherNoteUUID)]],
                ],
                ["@id": .string(attachmentUUID)],
            ]
        ]
        XCTAssertEqual(
            Set(NotesScriptIdentifierAnnotator.ids(in: result)),
            [noteUUID, folderUUID, otherNoteUUID, attachmentUUID]
        )
        let annotated = NotesScriptIdentifierAnnotator.annotate(
            result,
            scriptIDs: [noteUUID.uppercased(): script, folderUUID: "x-coredata://\(store)/ICFolder/p4"]
        )
        let items = annotated.objectValue?["itemListElement"]?.arrayValue ?? []
        let note = items[0].objectValue
        XCTAssertEqual(note?["identifier"]?.stringValue, noteUUID)
        XCTAssertEqual(note?["scriptIdentifier"]?.stringValue, script)
        XCTAssertEqual(
            note?["isPartOf"]?.objectValue?["scriptIdentifier"]?.stringValue,
            "x-coredata://\(store)/ICFolder/p4"
        )
        // A note the database gave no scripting id for, and an object it doesn't know, are left alone.
        let linked = note?["linkedNotes"]?.arrayValue?.first?.objectValue
        XCTAssertNil(linked?["scriptIdentifier"])
        XCTAssertNil(linked?["identifier"])
        XCTAssertNil(items[1].objectValue?["identifier"])
    }
}
