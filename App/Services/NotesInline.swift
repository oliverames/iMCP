import Foundation
import TopoText

// This file holds the parts of the Notes service that shape tags, links between notes,
// and smart folders for tool output. They take TopoText's plain values, not a database,
// so that tests can build the values.

/// Returns the result of a read of tags or links, or `nil` if the database's schema doesn't support the read.
///
/// TopoText throws ``NotesError/unsupportedSchema`` from these reads when the database
/// has no column that marks locked notes. The note or page is still readable then,
/// so the caller leaves out the fields that the read supplies instead of failing.
/// Every other error, including cancellation, propagates.
func readIfSupported<T>(_ read: () throws -> T) throws -> T? {
    do {
        return try read()
    } catch NotesError.unsupportedSchema {
        return nil
    }
}

/// The tags of a note as the note's `keywords`: `#name`, in the order the database lists them.
func keywordValues(_ tags: [TopoText.Note.Tag]) -> Value {
    .array(tags.map { .string($0.text) })
}

/// What a lookup found of the note at the other end of a link.
enum LinkedNote: Sendable, Equatable {
    /// Notes lists the note, with this title.
    case found(title: String)
    /// Notes doesn't list the note.
    case missing
    /// Nobody looked for the note, or the lookup failed for another reason.
    case unknown

    /// Looks up the note at the other end of a link.
    ///
    /// - Parameter lookup: Returns the title of the note, or throws if the lookup fails.
    ///
    /// Only ``NotesError/noteNotFound(_:)`` makes the note missing.
    /// The errors that leave the whole snapshot unusable propagate:
    /// cancellation, ``NotesError/connectionClosed``, and ``NotesError/timedOut``,
    /// because every statement of a snapshot shares one time limit.
    /// Any other error leaves the note unknown, so an existing note is never reported as missing.
    init(lookingUp lookup: () throws -> String) throws {
        do {
            self = .found(title: try lookup())
        } catch NotesError.noteNotFound {
            self = .missing
        } catch let error as CancellationError {
            throw error
        } catch NotesError.connectionClosed {
            throw NotesError.connectionClosed
        } catch NotesError.timedOut {
            throw NotesError.timedOut
        } catch {
            self = .unknown
        }
    }
}

/// A link between notes as an object for the note's `linkedNotes` or `linkedFrom`.
///
/// - Parameters:
///   - link: The link.
///   - direction: Whether the link leaves the note (`outgoing`) or arrives at it (`incoming`).
///   - other: What a lookup found of the note at the other end.
func linkValue(_ link: TopoText.Note.Link, direction: LinkDirection, other: LinkedNote) -> Value {
    let otherID = direction == .outgoing ? link.targetID : link.sourceID
    var object: [String: Value] = ["@id": .string(otherID.description)]
    if case .found(let title) = other, !title.isEmpty {
        object["name"] = .string(title)
    } else if direction == .outgoing, let label = link.label {
        // The label names the target, so it can stand in for the target's title but not for the source's.
        object["name"] = .string(label)
    }
    // The label can differ from the title, because it is the text of the link, which doesn't follow renames.
    if let label = link.label, label != object["name"]?.stringValue {
        object["linkText"] = .string(label)
    }
    if other == .missing {
        object["isMissing"] = true
    }
    return .object(object)
}

enum LinkDirection: Sendable {
    case outgoing
    case incoming
}
