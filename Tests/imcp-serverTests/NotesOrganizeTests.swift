import Foundation
import MCP
import TopoText
import XCTest
import os

final class NotesOrganizeTests: XCTestCase {
    private let noteID = "x-coredata://ABC/ICNote/p12"

    // MARK: - Fields

    private func noteFields(plain: String = "Plan\nline", locked: Bool = false, attachments: Int = 0) -> [String] {
        [
            noteID, "Plan", "x-coredata://ABC/ICFolder/p3", "Work",
            "2026-11-16T09:30:00", "2026-11-17T10:00:00", plain, "<div><h1>Plan</h1></div><div>line</div>",
            locked ? "true" : "false", "false", String(attachments), "iCloud",
        ]
    }

    func testNoteFieldsAreReadInOrder() throws {
        let note = try NotesScriptNote(fields: noteFields(attachments: 2))
        XCTAssertEqual(note.id, noteID)
        XCTAssertEqual(note.folder, "Work")
        XCTAssertEqual(note.account, "iCloud")
        XCTAssertEqual(note.attachmentCount, 2)
        XCTAssertFalse(note.isPasswordProtected)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(note.modified))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 11, 17, 10])
        XCTAssertThrowsError(try NotesScriptNote(fields: ["short"]))
    }

    func testContentHashIsStableAndTracksTheText() throws {
        let first = try NotesScriptNote(fields: noteFields(plain: "Plan\nline"))
        let same = try NotesScriptNote(fields: noteFields(plain: "Plan\nline"))
        let edited = try NotesScriptNote(fields: noteFields(plain: "Plan\nline!"))
        XCTAssertEqual(first.contentHash, same.contentHash)
        XCTAssertNotEqual(first.contentHash, edited.contentHash)
        XCTAssertEqual(first.contentHash.count, 64)
        // SHA-256 of "abc".
        XCTAssertEqual(
            NotesContentHash.hash(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testAStaleHashIsRefused() throws {
        let note = try NotesScriptNote(fields: noteFields(plain: "now"))
        XCTAssertNoThrow(try NotesContentHash.requireCurrent(note, expected: note.contentHash.uppercased()))
        XCTAssertThrowsError(try NotesContentHash.requireCurrent(note, expected: NotesContentHash.hash(of: "before"))) {
            XCTAssertEqual($0 as? NotesWriteError, .stale)
        }
        XCTAssertThrowsError(try NotesContentHash.requireCurrent(note, expected: "  "))
    }

    func testSummariesAreSortedAndLeaveOutDeletedNotes() throws {
        let fields = [
            "id1", "Old", "Work", "f1", "2026-01-01T00:00:00",
            "id2", "New", "Work", "f1", "2026-06-01T00:00:00",
            "id3", "Gone", "Recently Deleted", "f2", "2026-12-01T00:00:00",
        ]
        let recent = NotesScriptSummary.recent(try NotesScriptSummary.list(from: fields), limit: 5)
        XCTAssertEqual(recent.map(\.id), ["id2", "id1"])
        XCTAssertEqual(
            NotesScriptSummary.recent(try NotesScriptSummary.list(from: fields), limit: 1).map(\.id),
            ["id2"]
        )
        XCTAssertThrowsError(try NotesScriptSummary.list(from: ["a", "b"]))
    }

    func testFoldersFormATree() throws {
        let fields = [
            "a", "Work", "", "iCloud", "2",
            "b", "Clients", "a", "iCloud", "1",
            "c", "Stray", "missing", "iCloud", "0",
        ]
        let tree = NotesScriptFolder.tree(try NotesScriptFolder.list(from: fields))
        XCTAssertEqual(tree.map(\.folder.name), ["Work", "Stray"])
        XCTAssertEqual(tree[0].children.map(\.folder.name), ["Clients"])
        XCTAssertEqual(tree[0].folder.noteCount, 2)
    }

    // MARK: - Input

    func testNoteIDsMustBeCoreDataIDs() throws {
        XCTAssertEqual(try NotesOrganizeInput.validatedNoteID(" \(noteID) "), noteID)
        XCTAssertThrowsError(try NotesOrganizeInput.validatedNoteID("12"))
        XCTAssertThrowsError(try NotesOrganizeInput.validatedNoteID("x-coredata://a\nb"))
        XCTAssertThrowsError(try NotesOrganizeInput.validatedNoteIDs([]))
        XCTAssertThrowsError(
            try NotesOrganizeInput.validatedNoteIDs(
                Array(repeating: noteID, count: NotesOrganizeInput.maximumBatch + 1)
            )
        )
        XCTAssertThrowsError(try NotesOrganizeInput.validatedPath("relative/file", called: "path"))
        XCTAssertEqual(try NotesOrganizeInput.validatedPath("/tmp/a.png", called: "path"), "/tmp/a.png")
        XCTAssertThrowsError(try NotesOrganizeInput.validatedLimit(0, default: 20))
    }

    func testStagedFilenamesCantLeaveTheirFolder() throws {
        XCTAssertEqual(try NotesAttachmentStaging.safeFilename(" a.png "), "a.png")
        for bad in ["", "..", "a/b", "../x", "a\nb"] {
            XCTAssertThrowsError(try NotesAttachmentStaging.safeFilename(bad), bad)
        }
        let file = try NotesAttachmentStaging.stage(base64: Data("hello".utf8).base64EncodedString(), filename: "n.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
        XCTAssertThrowsError(try NotesAttachmentStaging.stage(base64: "!!!", filename: "n.txt"))
    }

    // MARK: - Scripts

    func testCallsPassEveryValueAsAParameter() throws {
        let text = #"" & (do shell script "id") & ""#
        let update = NotesOrganizeScripts.updateNote(id: noteID, expectedPlainText: text, bodyHTML: text)
        XCTAssertEqual(update.parameters, [.string(noteID), .string(text), .string(text)])
        let path = try NotesFolderPath.parse("A/\(text)")
        XCTAssertEqual(
            NotesOrganizeScripts.deleteFolder(account: text, folder: path, deleteContents: true).parameters,
            [.string(text), .strings(["A", text]), .boolean(true)]
        )
        let append = NotesOrganizeScripts.appendToNote(id: noteID, expectedPlainText: nil, additionHTML: "x")
        XCTAssertEqual(append.parameters[2], .boolean(false))
        XCTAssertFalse(NotesOrganizeScripts.organizeSource.contains("do shell script"))
    }

    func testEveryHandlerTheToolsCallIsInTheScript() {
        let calls = [
            NotesOrganizeScripts.getNote("x"), NotesOrganizeScripts.selectedNotes, NotesOrganizeScripts.defaultLocation,
            NotesOrganizeScripts.listFolders(account: nil), NotesOrganizeScripts.deleteNote("x"),
            NotesOrganizeScripts.showNote("x"), NotesOrganizeScripts.listAttachments("x"),
            NotesOrganizeScripts.addAttachment(id: "x", path: "/a"),
            NotesOrganizeScripts.saveAttachment(id: "x", attachmentID: "y", path: "/a"),
            NotesOrganizeScripts.updateNote(id: "x", expectedPlainText: "", bodyHTML: ""),
            NotesOrganizeScripts.appendToNote(id: "x", expectedPlainText: nil, additionHTML: ""),
            NotesOrganizeScripts.listNotes(account: nil, folder: NotesFolderPath(components: [])),
            NotesOrganizeScripts.moveNote(id: "x", account: nil, folder: NotesFolderPath(components: ["A"])),
            NotesOrganizeScripts.renameFolder(account: nil, folder: NotesFolderPath(components: ["A"]), newName: "B"),
            NotesOrganizeScripts.showFolder(account: nil, folder: NotesFolderPath(components: ["A"])),
        ]
        for call in calls {
            XCTAssertTrue(NotesOrganizeScripts.source.contains("on \(call.name)("), call.name)
        }
    }

    // MARK: - Markdown and exports

    func testNotesHTMLBecomesMarkdown() {
        let html =
            "<div><h1>Plan</h1></div><div>Some <b>bold</b> and <i>italic</i> with <a href=\"https://example.com/a?b=1&amp;c=2\">a link</a> &amp; more</div><div><br></div><div><h2>Steps</h2></div><ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol><li>first</li><li>second</li></ol><div><tt>code</tt></div>"
        XCTAssertEqual(
            NotesHTMLToMarkdown.markdown(fromHTML: html),
            """
            # Plan
            Some **bold** and *italic* with [a link](https://example.com/a?b=1&c=2) & more

            ## Steps
            - one
            - two
              - nested
            1. first
            2. second
            `code`
            """
        )
    }

    func testTablesImagesAndEntitiesConvert() {
        let html =
            "<table><tr><td>A</td><td>B|C</td></tr><tr><td>1</td><td>2</td></tr></table><div>caf&#233; &lt;tag&gt;<img src=\"cid:x\"></div><style>p{}</style><!-- hidden --><div>end</div>"
        XCTAssertEqual(
            NotesHTMLToMarkdown.markdown(fromHTML: html),
            """
            | A | B\\|C |
            | --- | --- |
            | 1 | 2 |
            café <tag>[image]
            end
            """
        )
    }

    func testHeadIsSkippedButTheBodyAfterItIsKept() {
        let html = "<html><head><title>T</title><style>p{}</style></head><body><div>kept</div></body></html>"
        XCTAssertEqual(NotesHTMLToMarkdown.markdown(fromHTML: html), "kept")
    }

    private func item(_ title: String, locked: Bool = false) throws -> NotesExportItem {
        var fields = noteFields(plain: "\(title)\nbody")
        fields[1] = title
        fields[7] = "<div><h1>\(title)</h1></div><div>body</div>"
        fields[8] = locked ? "true" : "false"
        return NotesExportItem(try NotesScriptNote(fields: fields))
    }

    func testExportsInEveryFormat() throws {
        let items = [try item("One"), try item("Two \"quoted\""), try item("Locked", locked: true)]

        let json = try NotesExporter.export(items, as: .json)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[1]["title"] as? String, "Two \"quoted\"")
        XCTAssertEqual(decoded[0]["plainText"] as? String, "One\nbody")
        XCTAssertEqual(decoded[2]["locked"] as? Bool, true)

        let markdown = try NotesExporter.export(items, as: .markdown)
        XCTAssertTrue(markdown.contains("title: \"Two \\\"quoted\\\"\""))
        XCTAssertTrue(markdown.contains("# One\nbody"))
        XCTAssertTrue(markdown.contains("id: \"x-coredata://ABC/ICNote/p12\""))

        let html = try NotesExporter.export(items, as: .html)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertEqual(html.components(separatedBy: "<article").count - 1, 3)
        XCTAssertTrue(html.contains("This note is locked with a password."))
        XCTAssertFalse(html.contains("<h1>Locked</h1>"))
    }

    // MARK: - Tools

    private final class FakeRunner: NotesScriptRunning {
        private let calls = OSAllocatedUnfairLock(initialState: [NSAppleScript.Subroutine]())
        var recorded: [NSAppleScript.Subroutine] { calls.withLock { $0 } }
        let plain: String
        let html: String
        let shared: Bool
        let failingIDs: Set<String>

        init(
            plain: String = "Plan\nline",
            html: String = "<div><h1>Plan</h1></div>",
            shared: Bool = false,
            failingIDs: Set<String> = []
        ) {
            self.plain = plain
            self.html = html
            self.shared = shared
            self.failingIDs = failingIDs
        }

        func run(_ source: String, calling subroutine: NSAppleScript.Subroutine) async throws -> [String] {
            calls.withLock { $0.append(subroutine) }
            if case .string(let id)? = subroutine.parameters.first, failingIDs.contains(id) {
                throw NotesWriteError.scriptFailed("There is no note with the id: \(id)")
            }
            switch subroutine.name {
            case "getNote":
                return [
                    "x-coredata://ABC/ICNote/p12", "Plan", "f", "Work", "2026-11-16T09:30:00", "2026-11-17T10:00:00",
                    plain, html, "false", shared ? "true" : "false", "0", "iCloud",
                ]
            case "updateNote", "appendToNote": return ["x-coredata://ABC/ICNote/p12", "Plan", "2026-11-17T11:00:00"]
            case "deleteNote": return ["x-coredata://ABC/ICNote/p12", "Plan"]
            case "moveNote": return ["x-coredata://ABC/ICNote/p13", "Plan", "Archive"]
            default: return []
            }
        }
    }

    private func tools(
        enabled: Bool = true,
        runner: FakeRunner = FakeRunner(),
        attachmentFolder: URL = NotesAttachmentFolder.defaultURL
    ) -> [String: Tool] {
        Dictionary(
            uniqueKeysWithValues: NotesOrganizeTools.tools(
                isEnabled: { enabled },
                runner: runner,
                attachmentFolder: attachmentFolder,
                traitLookup: { _ in NoteTraits(content: TopoText.Note.Content(paragraphs: [])) }
            ).map { ($0.name, $0) }
        )
    }

    func testToolSetsMatchTheirNames() {
        let all = tools()
        XCTAssertEqual(Set(all.keys), NotesOrganizeTools.readToolNames.union(NotesOrganizeTools.writeToolNames))
        for name in NotesOrganizeTools.readToolNames {
            XCTAssertEqual(all[name]?.annotations.readOnlyHint, true, name)
        }
        for name in NotesOrganizeTools.writeToolNames {
            XCTAssertEqual(all[name]?.annotations.readOnlyHint, false, name)
        }
        XCTAssertTrue(NotesOrganizeTools.readToolNames.isDisjoint(with: NotesOrganizeTools.writeToolNames))
    }

    func testEveryWriteToolRefusesWhileChangesAreOff() async {
        let runner = FakeRunner()
        let all = tools(enabled: false, runner: runner)
        let arguments: [String: Value] = [
            "id": .string(noteID), "ids": [.string(noteID)], "folder": "A", "newName": "B", "body": "x", "text": "x",
            "expectedContentHash": "h", "path": "/tmp/a", "attachmentId": "a",
        ]
        for name in NotesOrganizeTools.writeToolNames {
            do {
                _ = try await all[name]!(arguments)
                XCTFail("\(name) ran")
            } catch {
                XCTAssertEqual(error as? NotesWriteError, .writesDisabled, name)
            }
        }
        XCTAssertTrue(runner.recorded.isEmpty)
    }

    func testUpdateWritesOnlyWhenTheHashIsCurrent() async throws {
        let runner = FakeRunner(plain: "Plan\nline")
        let all = tools(runner: runner)
        let hash = NotesContentHash.hash(of: "Plan\nline")

        _ = try await all["notes_update"]!([
            "id": .string(noteID), "expectedContentHash": .string(hash), "body": "new <body>",
        ])
        let update = try XCTUnwrap(runner.recorded.last)
        XCTAssertEqual(update.name, "updateNote")
        XCTAssertEqual(update.parameters[1], .string("Plan\nline"))
        XCTAssertEqual(
            update.parameters[2],
            .string("<div><h1>Plan</h1></div><div>new &lt;body&gt;</div>")
        )

        let before = runner.recorded.count
        do {
            _ = try await all["notes_update"]!([
                "id": .string(noteID), "expectedContentHash": .string(NotesContentHash.hash(of: "older")), "body": "x",
            ])
            XCTFail("a stale update ran")
        } catch {
            XCTAssertEqual(error as? NotesWriteError, .stale)
        }
        // Only the read happened.
        XCTAssertEqual(runner.recorded.count, before + 1)
        XCTAssertEqual(runner.recorded.last?.name, "getNote")
    }

    // MARK: - Rewrite guard

    private typealias Content = TopoText.Note.Content
    private typealias Paragraph = TopoText.Note.Paragraph
    private typealias Run = TopoText.Note.TextRun

    private func traits(_ paragraphs: [Paragraph]) -> NoteTraits {
        NoteTraits(content: Content(paragraphs: paragraphs))
    }

    private func inline(_ id: String, type: String, text: String? = nil) -> Run {
        Run(
            text: "\u{FFFC}",
            attachment: TopoText.Note.Attachment(
                id: TopoText.Note.Attachment.ID(id)!,
                typeIdentifier: type,
                displayText: text,
                title: id,
                url: nil,
                fileName: nil
            )
        )
    }

    private var plainTraits: NoteTraits { traits([Paragraph(runs: [Run(text: "Plan line")])]) }
    private var checklistTraits: NoteTraits {
        traits([Paragraph(style: .init(kind: .checklist), runs: [Run(text: "Passport")])])
    }
    private var tagTraits: NoteTraits {
        traits([
            Paragraph(runs: [
                Run(text: "Trip "), inline("T1", type: "com.apple.notes.inlinetextattachment.hashtag", text: "#Travel"),
            ])
        ])
    }
    private var linkTraits: NoteTraits {
        traits([Paragraph(runs: [Run(text: "docs", link: "https://example.com/docs")])])
    }
    private var tableTraits: NoteTraits {
        traits([Paragraph(runs: [inline("TB", type: "com.apple.notes.table")])])
    }

    private struct LookupFailed: Error {}

    private func updateAndAppend(
        for runner: FakeRunner,
        lookup: @escaping NotesTraitLookup
    ) -> [(String, () async throws -> Value)] {
        let all = Dictionary(
            uniqueKeysWithValues: NotesOrganizeTools.tools(
                isEnabled: { true },
                runner: runner,
                traitLookup: lookup
            ).map { ($0.name, $0) }
        )
        let hash = NotesContentHash.hash(of: runner.plain)
        let id = noteID
        return [
            (
                "notes_update",
                {
                    try await all["notes_update"]!([
                        "id": .string(id), "expectedContentHash": .string(hash), "body": "x",
                    ])
                }
            ),
            ("notes_append", { try await all["notes_append"]!(["id": .string(id), "text": "x"]) }),
            (
                "notes_append+hash",
                {
                    try await all["notes_append"]!([
                        "id": .string(id), "text": "x", "expectedContentHash": .string(hash),
                    ])
                }
            ),
        ]
    }

    func testUpdateAndAppendRefuseNotesThatWouldLoseStructure() async throws {
        let checklist = checklistTraits, tag = tagTraits, link = linkTraits, table = tableTraits, plain = plainTraits
        let refused: [(String, FakeRunner, NotesTraitLookup, String)] = [
            ("checklist", FakeRunner(), { _ in checklist }, "checklist"),
            ("tag", FakeRunner(), { _ in tag }, "native tags"),
            ("link", FakeRunner(), { _ in link }, "links"),
            ("table", FakeRunner(), { _ in table }, "table"),
            ("unreadable", FakeRunner(), { _ in throw LookupFailed() }, "could not check the note's structure"),
            ("U+FFFC", FakeRunner(plain: "Plan\n\u{FFFC} x"), { _ in plain }, "inline objects"),
            ("shared", FakeRunner(shared: true), { _ in plain }, "shared"),
        ]
        for (label, runner, lookup, expected) in refused {
            for (tool, call) in updateAndAppend(for: runner, lookup: lookup) {
                do {
                    _ = try await call()
                    XCTFail("\(tool) rewrote a \(label) note")
                } catch {
                    let message = (error as? NotesWriteError)?.errorDescription ?? "\(error)"
                    XCTAssertTrue(message.contains(expected), "\(label) \(tool): \(message)")
                    XCTAssertTrue(message.contains("notes_append_rich"), "\(label) \(tool): \(message)")
                }
            }
            XCTAssertFalse(
                runner.recorded.contains { ["updateNote", "appendToNote"].contains($0.name) },
                "\(label) note was written"
            )
        }

        // A plain note still works, with and without a hash.
        let runner = FakeRunner()
        for (_, call) in updateAndAppend(for: runner, lookup: { _ in plain }) { _ = try await call() }
        XCTAssertEqual(runner.recorded.filter { ["updateNote", "appendToNote"].contains($0.name) }.count, 3)
    }

    // MARK: - Attachment folder

    private func makeFolder() throws -> (root: URL, folder: URL, outside: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imcp-folder-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("attachments")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (root, folder, outside)
    }

    func testAttachmentPathsMustStayInsideTheFolder() throws {
        let (root, folder, outside) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = folder.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: inside)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("s".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link.txt"),
            withDestinationURL: secret
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("dir"),
            withDestinationURL: outside
        )

        XCTAssertNoThrow(try NotesAttachmentFolder.resolveExisting(inside.path, in: folder))
        XCTAssertThrowsError(try NotesAttachmentFolder.resolveExisting(secret.path, in: folder))
        XCTAssertThrowsError(
            try NotesAttachmentFolder.resolveExisting(folder.path + "/../outside/secret.txt", in: folder)
        )
        XCTAssertThrowsError(try NotesAttachmentFolder.resolveExisting(folder.path + "/link.txt", in: folder))
        XCTAssertThrowsError(try NotesAttachmentFolder.resolveExisting(folder.path + "/dir/secret.txt", in: folder))
        XCTAssertThrowsError(try NotesAttachmentFolder.resolveExisting(folder.path, in: folder))

        XCTAssertNoThrow(try NotesAttachmentFolder.resolveNew(folder.path + "/new.png", in: folder))
        XCTAssertThrowsError(try NotesAttachmentFolder.resolveNew(outside.path + "/new.png", in: folder))
        XCTAssertThrowsError(try NotesAttachmentFolder.resolveNew(folder.path + "/../outside/new.png", in: folder))
        XCTAssertThrowsError(try NotesAttachmentFolder.resolveNew(folder.path + "/dir/new.png", in: folder))
    }

    func testAttachmentToolsRefusePathsOutsideTheFolder() async throws {
        let (root, folder, outside) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = folder.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: inside)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("s".utf8).write(to: secret)
        let runner = FakeRunner()
        let all = tools(runner: runner, attachmentFolder: folder)

        do {
            _ = try await all["notes_add_attachment"]!(["id": .string(noteID), "path": .string(secret.path)])
            XCTFail("attached a file outside the folder")
        } catch {
            XCTAssertNotNil(error as? NotesWriteError)
        }
        do {
            _ = try await all["notes_save_attachment"]!([
                "id": .string(noteID), "attachmentId": "a", "path": .string(outside.path + "/out.png"),
            ])
            XCTFail("saved a file outside the folder")
        } catch {
            XCTAssertNotNil(error as? NotesWriteError)
        }
        XCTAssertTrue(runner.recorded.isEmpty)

        _ = try await all["notes_add_attachment"]!(["id": .string(noteID), "path": .string(inside.path)])
        _ = try await all["notes_save_attachment"]!([
            "id": .string(noteID), "attachmentId": "a", "path": .string(folder.path + "/out.png"),
        ])
        XCTAssertEqual(runner.recorded.map(\.name), ["addAttachment", "saveAttachment"])
    }

    func testBatchesReportEachNote() async throws {
        let bad = "x-coredata://ABC/ICNote/p99"
        let runner = FakeRunner(failingIDs: [bad])
        let all = tools(runner: runner)
        let result = try await all["notes_batch_move"]!([
            "ids": [.string(noteID), .string(bad)], "folder": "Archive",
        ])
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["succeeded"]?.intValue, 1)
        XCTAssertEqual(object["failed"]?.intValue, 1)
        let rows = try XCTUnwrap(object["results"]?.arrayValue)
        XCTAssertEqual(rows[0].objectValue?["newId"]?.stringValue, "x-coredata://ABC/ICNote/p13")
        XCTAssertEqual(rows[1].objectValue?["ok"]?.boolValue, false)
    }
}
