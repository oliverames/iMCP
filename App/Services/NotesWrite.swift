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
///
/// The two routes name a note differently, so every tool takes either id and returns both
/// (`NotesIDMapper`).
extension NotesService {
    var tools: [Tool] {
        readTools
            + NotesWriteTools.tools(
                isEnabled: { NotesWriteTools.isEnabledInSettings },
                runner: AppleNotesScriptRunner(),
                mapper: idMapper
            )
            + NotesOrganizeTools.tools(
                isEnabled: { NotesWriteTools.isEnabledInSettings },
                runner: AppleNotesScriptRunner(),
                mapper: idMapper,
                traitLookup: { try await NotesService.shared.traits(ofScriptedNote: $0) }
            )
            + NotesPrivateTools.tools
    }

    /// The tools that change notes are new, so they start off until the person turns writes on.
    var writesEnabledByDefault: Bool { false }
}
