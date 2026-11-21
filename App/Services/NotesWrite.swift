import Foundation

/// The Notes service's tools that change the Notes app.
///
/// Reading and changing use different routes:
/// notes are read from the database with TopoText, which never writes to it,
/// and a new note or folder is made through the Notes app's own scripting interface,
/// so Notes stores it as it stores anything else that it makes.
/// `notes_update` and `notes_append` also edit an existing note through scripting, which sets the
/// whole HTML body and so drops checklist state, native tags, tables, link previews, and attachments
/// without an error. They refuse a note that has any of these, or is shared (`NotesRewriteGuard`),
/// and `notes_append_rich` adds text to such a note through Notes' own editor.
extension NotesService {
    var tools: [Tool] {
        readTools
            + NotesWriteTools.tools(
                isEnabled: { NotesWriteTools.isEnabledInSettings },
                runner: AppleNotesScriptRunner(),
                resolver: DatabaseIdentifierResolver(service: self)
            )
            + NotesOrganizeTools.tools(
                isEnabled: { NotesWriteTools.isEnabledInSettings },
                runner: AppleNotesScriptRunner(),
                traitLookup: { try await NotesService.shared.traits(ofScriptedNote: $0) }
            )
            + NotesPrivateTools.tools
    }

    /// The tools that change notes are new, so they start off until the person turns writes on.
    var writesEnabledByDefault: Bool { false }
}

/// Looks in the Notes database through the Notes service.
struct DatabaseIdentifierResolver: NotesIdentifierResolving, @unchecked Sendable {
    let service: NotesService

    func noteID(
        title: String,
        folderPath: [String],
        folderName: String,
        accountName: String,
        createdAfter date: Date
    ) async -> String? {
        await service.lookUpCreatedNote(
            title: title,
            folderPath: folderPath,
            folderName: folderName,
            accountName: accountName,
            createdAfter: date
        )
    }

    func folderID(path: [String], accountName: String) async -> String? {
        await service.lookUpCreatedFolder(path: path, accountName: accountName)
    }
}
