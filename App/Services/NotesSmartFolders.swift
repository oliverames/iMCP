import Foundation
import TopoText

// Smart folders for the Notes tools: the stored query and the folder as tool output.

/// A smart folder as an object for tool output, with its rules read from the stored query.
/// - Parameter folderNames: The names of the folders, by identifier, for the name of the parent folder.
func smartFolderValue(_ folder: TopoText.SmartFolder, folderNames: [TopoText.Folder.ID: String]) -> Value {
    var object: [String: Value] = [
        "@id": .string(folder.id.description),
        "@type": "SmartFolder",
        "name": .string(folder.name),
    ]
    if let accountName = folder.account?.name {
        object["account"] = .string(accountName)
    }
    if let parentID = folder.parentID {
        var parent: [String: Value] = ["@id": .string(parentID.description)]
        if let name = folderNames[parentID] {
            parent["name"] = .string(name)
        }
        object["parentFolder"] = .object(parent)
    }
    let query = SmartFolderQuery(folder.query)
    if let rules = query.rules {
        object["rules"] = rules
    }
    if query.includesRecentlyDeleted == true {
        object["includesRecentlyDeleted"] = true
    }
    // The stored text stays available, because rules that this server doesn't know are not explained.
    object["query"] = .string(folder.query)
    return .object(object)
}

/// The query that Notes stores for a smart folder.
///
/// Notes stores `{"entity":"note","type":{"and":[{"deleted":false}, <rules>…]}}`.
/// The `deleted` clause only keeps Recently Deleted out of the results,
/// so the rules are what remains of the `and` clause.
/// Notes doesn't document the format, so anything else is kept whole as the rules.
struct SmartFolderQuery: Sendable, Equatable {
    /// The rules of the folder as JSON, or `nil` if the text is not JSON.
    private(set) var rules: Value?
    /// Whether the folder includes Recently Deleted, if the query says.
    private(set) var includesRecentlyDeleted: Bool?

    init(_ text: String) {
        guard let value = try? JSONDecoder().decode(Value.self, from: Data(text.utf8)) else { return }
        rules = value
        guard let type = value.objectValue?["type"], let clauses = type.objectValue?["and"]?.arrayValue else {
            if let type = value.objectValue?["type"] {
                rules = type
            }
            return
        }
        var rest: [Value] = []
        for clause in clauses {
            if let object = clause.objectValue, object.count == 1, let deleted = object["deleted"]?.boolValue {
                includesRecentlyDeleted = deleted
            } else {
                rest.append(clause)
            }
        }
        rules = rest.count == 1 ? rest[0] : .object(["and": .array(rest)])
    }
}
