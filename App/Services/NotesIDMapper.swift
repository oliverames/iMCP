import Foundation
import MCP
import SQLite3

// Notes names a note or folder two ways.
// The database, and so the tools that read it with TopoText, use the row's UUID (`ZIDENTIFIER`).
// The scripting interface, and so the tools that edit, use `x-coredata://<store UUID>/ICNote/p<Z_PK>`.
// Nothing in a script id is the UUID, so the two are joined by reading the database's own rows:
// the store UUID is `Z_METADATA.Z_UUID`, and `Z_PK` is the row's key (TopoText's `NoteStore` article).
// The mapping is exact: a row is found by its UUID or by its key, never by its title or date.

/// What a Notes identifier names.
enum NotesIDKind: Sendable, Equatable {
    case note
    case folder

    /// The Core Data entity, which is also the middle part of a script id.
    var entityName: String {
        switch self {
        case .note: "ICNote"
        case .folder: "ICFolder"
        }
    }
}

/// A scripting id, `x-coredata://<store UUID>/ICNote/p<Z_PK>`, taken apart.
struct NotesScriptID: Equatable, Sendable {
    static let prefix = "x-coredata://"

    var storeUUID: String
    var kind: NotesIDKind
    var primaryKey: Int64

    init(storeUUID: String, kind: NotesIDKind, primaryKey: Int64) {
        self.storeUUID = storeUUID
        self.kind = kind
        self.primaryKey = primaryKey
    }

    /// Parses the exact form that Notes reports for a note or a folder, or returns `nil`.
    init?(_ text: String) {
        guard text.hasPrefix(Self.prefix) else { return nil }
        let parts = text.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
            let kind = [NotesIDKind.note, .folder].first(where: { $0.entityName == parts[1] }),
            parts[2].hasPrefix("p"), parts[2].count > 1, parts[2].dropFirst().allSatisfy(\.isASCII),
            parts[2].dropFirst().allSatisfy(\.isNumber),
            let key = Int64(parts[2].dropFirst())
        else { return nil }
        self.init(storeUUID: String(parts[0]), kind: kind, primaryKey: key)
    }

    var description: String {
        "\(Self.prefix)\(storeUUID)/\(kind.entityName)/p\(primaryKey)"
    }
}

/// Why an identifier could not be translated.
enum NotesIDMapperError: LocalizedError, Equatable {
    /// The database can't be read, and the Notes app bridge isn't available either.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Notes' two kinds of id can't be translated right now: \(reason)"
        }
    }
}

/// Translates between a note's or folder's database UUID and its scripting id.
protocol NotesIDMapping: Sendable {
    /// The scripting ids of the rows with these UUIDs, keyed by uppercased UUID.
    /// A UUID that no row has is left out. Throws when the database can't be read.
    func scriptIDs(forUUIDs uuids: [String], kind: NotesIDKind) async throws -> [String: String]

    /// The UUIDs of the rows with these scripting ids, keyed by the scripting id as given.
    /// A scripting id that no row has, or that is not in the database's own form, is left out.
    func uuids(forScriptIDs ids: [String]) async throws -> [String: String]
}

// MARK: - The database

/// Reads the translation from the Notes database, through the person's grant of access to its folder.
struct NotesDatabaseIDMapper: NotesIDMapping {
    /// Runs a read inside the grant of access to the Notes folder.
    typealias FolderAccess =
        @Sendable (_ read: @Sendable (URL) throws -> [String: String]) async throws -> [String: String]

    let access: FolderAccess

    func scriptIDs(forUUIDs uuids: [String], kind: NotesIDKind) async throws -> [String: String] {
        let wanted = Set(uuids.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        return try await access { folder in
            try NotesIDTable.scriptIDs(
                databaseAt: folder.appendingPathComponent(NotesIDTable.databaseFileName),
                uuids: wanted,
                kind: kind
            )
        }
    }

    func uuids(forScriptIDs ids: [String]) async throws -> [String: String] {
        let parsed = Dictionary(ids.compactMap { id in NotesScriptID(id).map { (id, $0) } }) { first, _ in first }
        guard !parsed.isEmpty else { return [:] }
        return try await access { folder in
            try NotesIDTable.uuids(
                databaseAt: folder.appendingPathComponent(NotesIDTable.databaseFileName),
                scriptIDs: parsed
            )
        }
    }
}

/// The queries of the translation, against one database file, opened read-only.
enum NotesIDTable {
    static let databaseFileName = "NoteStore.sqlite"
    private static let chunkSize = 200

    static func scriptIDs(databaseAt url: URL, uuids: Set<String>, kind: NotesIDKind) throws -> [String: String] {
        try withConnection(url) { connection in
            guard let store = try storeUUID(connection), let entity = try entity(named: kind.entityName, connection)
            else { return [:] }
            var found: [String: String] = [:]
            for chunk in Array(uuids).chunked(into: chunkSize) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try run(
                    connection,
                    "SELECT Z_PK, ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ? AND UPPER(ZIDENTIFIER) IN (\(marks))",
                    [.integer(entity)] + chunk.map { .text($0) }
                ) { statement in
                    guard let uuid = text(statement, 1) else { return }
                    let key = sqlite3_column_int64(statement, 0)
                    found[uuid.uppercased()] = NotesScriptID(storeUUID: store, kind: kind, primaryKey: key).description
                }
            }
            return found
        }
    }

    /// - Parameter scriptIDs: The parsed ids, keyed by the text the caller gave.
    static func uuids(databaseAt url: URL, scriptIDs: [String: NotesScriptID]) throws -> [String: String] {
        try withConnection(url) { connection in
            guard let store = try storeUUID(connection) else { return [:] }
            var found: [String: String] = [:]
            for kind in [NotesIDKind.note, .folder] {
                // An id from another database, such as a restored backup's, names nothing here.
                let own = scriptIDs.filter {
                    $0.value.kind == kind && $0.value.storeUUID.uppercased() == store.uppercased()
                }
                guard !own.isEmpty, let entity = try entity(named: kind.entityName, connection) else { continue }
                let byKey = Dictionary(grouping: own.keys, by: { own[$0]!.primaryKey })
                for chunk in Array(byKey.keys).chunked(into: chunkSize) {
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    try run(
                        connection,
                        "SELECT Z_PK, ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ? AND Z_PK IN (\(marks))",
                        [.integer(entity)] + chunk.map { .integer($0) }
                    ) { statement in
                        guard let uuid = text(statement, 1) else { return }
                        for given in byKey[sqlite3_column_int64(statement, 0)] ?? [] { found[given] = uuid }
                    }
                }
            }
            return found
        }
    }

    // MARK: SQLite

    private enum Binding {
        case integer(Int64)
        case text(String)
    }

    private static func storeUUID(_ connection: OpaquePointer) throws -> String? {
        var uuid: String?
        try run(connection, "SELECT Z_UUID FROM Z_METADATA LIMIT 1", []) { uuid = text($0, 0) }
        guard let uuid, !uuid.isEmpty else { return nil }
        return uuid
    }

    private static func entity(named name: String, _ connection: OpaquePointer) throws -> Int64? {
        var number: Int64?
        try run(connection, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = ?", [.text(name)]) {
            number = sqlite3_column_int64($0, 0)
        }
        return number
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func run(
        _ connection: OpaquePointer,
        _ sql: String,
        _ bindings: [Binding],
        row: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw NotesIDMapperError.unavailable(
                "the Notes database has an unexpected layout (\(String(cString: sqlite3_errmsg(connection))))"
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            switch binding {
            case .integer(let value): sqlite3_bind_int64(statement, Int32(offset + 1), value)
            case .text(let value): sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
            }
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            row(statement)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw NotesIDMapperError.unavailable(
                "the Notes database could not be read (\(String(cString: sqlite3_errmsg(connection))))"
            )
        }
    }

    /// Opens the database read-only, as TopoText does: in place, with a short busy timeout, and,
    /// when the folder is read-only and has no write-ahead log, reading the main file alone.
    private static func withConnection<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let connection = try open(url, immutable: false) ?? open(url, immutable: true)
        guard let connection else {
            throw NotesIDMapperError.unavailable("the Notes database can't be opened")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 1000)
        return try body(connection)
    }

    private static func open(_ url: URL, immutable: Bool) throws -> OpaquePointer? {
        var filename = url.path
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if immutable {
            // Without a log, every record is in the main file. With one, it must be read through SQLite.
            guard !FileManager.default.fileExists(atPath: url.path + "-wal") else { return nil }
            var components = URLComponents()
            components.scheme = "file"
            components.path = url.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components.string else { return nil }
            filename = uri
            flags |= SQLITE_OPEN_URI
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NotesIDMapperError.unavailable("the Notes database wasn't found")
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(filename, &connection, flags, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return nil
        }
        // The first statement reads the file, so its failure means the file is not readable.
        var probe: OpaquePointer?
        let readable =
            sqlite3_prepare_v2(connection, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &probe, nil) == SQLITE_OK
            && [SQLITE_ROW, SQLITE_DONE].contains(sqlite3_step(probe))
        sqlite3_finalize(probe)
        guard readable else {
            sqlite3_close(connection)
            return nil
        }
        return connection
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}

// MARK: - The bridge

/// Translates note ids through the NotesShared bridge, which reports both ids of a note.
/// It reads notes only, and only while "Private Notes features" is on.
struct NotesBridgeIDMapper: NotesIDMapping {
    /// The scripting id and the UUID that Notes reports for a note named by either.
    typealias Lookup = @Sendable (_ id: String) async throws -> (scriptID: String?, uuid: String?)

    let isAvailable: @Sendable () -> Bool
    let lookup: Lookup

    static let live = NotesBridgeIDMapper(
        isAvailable: { NotesPrivate.isEnabled() },
        lookup: { id in
            let structure = try await NotesPrivate.run(tool: "notes_structure", arguments: ["id": id])
            return (structure["id"] as? String, structure["identifier"] as? String)
        }
    )

    func scriptIDs(forUUIDs uuids: [String], kind: NotesIDKind) async throws -> [String: String] {
        guard kind == .note, isAvailable() else {
            throw NotesIDMapperError.unavailable("the bridge can't translate this")
        }
        var found: [String: String] = [:]
        for uuid in Set(uuids.map { $0.uppercased() }) {
            if let script = try? await lookup(uuid).scriptID { found[uuid] = script }
        }
        return found
    }

    func uuids(forScriptIDs ids: [String]) async throws -> [String: String] {
        guard isAvailable() else { throw NotesIDMapperError.unavailable("Private Notes features are off") }
        var found: [String: String] = [:]
        for id in ids {
            guard let parsed = NotesScriptID(id), parsed.kind == .note else { continue }
            if let uuid = try? await lookup(id).uuid { found[id] = uuid }
        }
        return found
    }
}

/// Tries the database first, and the bridge only when the database can't be read.
struct FallbackNotesIDMapper: NotesIDMapping {
    let primary: any NotesIDMapping
    let fallback: any NotesIDMapping

    func scriptIDs(forUUIDs uuids: [String], kind: NotesIDKind) async throws -> [String: String] {
        do {
            return try await primary.scriptIDs(forUUIDs: uuids, kind: kind)
        } catch let first {
            do { return try await fallback.scriptIDs(forUUIDs: uuids, kind: kind) } catch { throw first }
        }
    }

    func uuids(forScriptIDs ids: [String]) async throws -> [String: String] {
        do {
            return try await primary.uuids(forScriptIDs: ids)
        } catch let first {
            do { return try await fallback.uuids(forScriptIDs: ids) } catch { throw first }
        }
    }
}

/// Translates nothing, for a service that can't read the database.
struct NoNotesIDMapper: NotesIDMapping {
    func scriptIDs(forUUIDs uuids: [String], kind: NotesIDKind) async throws -> [String: String] {
        throw NotesIDMapperError.unavailable("no database is available")
    }
    func uuids(forScriptIDs ids: [String]) async throws -> [String: String] {
        throw NotesIDMapperError.unavailable("no database is available")
    }
}

// MARK: - Using the mapper in tools

/// A note or folder as a caller names it: by database UUID or by scripting id.
enum NotesReference: Equatable, Sendable {
    case uuid(String)
    case script(String)

    /// The reference as the caller wrote it, with a UUID in capitals.
    var text: String {
        switch self {
        case .uuid(let text), .script(let text): text
        }
    }

    /// Accepts a UUID, or a scripting id in the form that Notes reports, and nothing else.
    static func parse(_ text: String, label: String, kind: NotesIDKind) throws -> NotesReference {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: text) != nil { return .uuid(text.uppercased()) }
        let noControls = !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        if text.hasPrefix(NotesScriptID.prefix), text.count <= 500, noControls { return .script(text) }
        throw NotesWriteError.invalid(
            "\(label) must be a \(kind == .note ? "note" : "folder")'s UUID, or its id as the Notes app reports it, starting with x-coredata://"
        )
    }
}

/// A reference turned into the scripting id that the Notes app takes, with the UUID when it is known.
struct NotesResolved: Equatable, Sendable {
    var scriptID: String
    var uuid: String?
}

extension NotesIDMapping {
    /// The scripting id of each reference, in order. A reference that can't be resolved has its own error.
    func resolve(_ references: [NotesReference], kind: NotesIDKind) async -> [Result<NotesResolved, Error>] {
        let uuids = references.compactMap { reference -> String? in
            if case .uuid(let uuid) = reference { uuid } else { nil }
        }
        let found: Result<[String: String], Error>
        if uuids.isEmpty {
            found = .success([:])
        } else {
            do { found = .success(try await scriptIDs(forUUIDs: uuids, kind: kind)) } catch { found = .failure(error) }
        }
        return references.map { reference in
            switch reference {
            case .script(let id):
                return .success(NotesResolved(scriptID: id, uuid: nil))
            case .uuid(let uuid):
                switch found {
                case .failure(let error):
                    return .failure(
                        NotesWriteError.invalid(
                            "\(error.localizedDescription) Pass the id that starts with x-coredata:// instead."
                        )
                    )
                case .success(let ids):
                    guard let id = ids[uuid.uppercased()] else {
                        return .failure(
                            NotesWriteError.invalid(
                                "no \(kind == .note ? "note" : "folder") has the UUID \(uuid); use a UUID or x-coredata:// id that Notes reported"
                            )
                        )
                    }
                    return .success(NotesResolved(scriptID: id, uuid: uuid))
                }
            }
        }
    }

    func resolve(_ reference: NotesReference, kind: NotesIDKind) async throws -> NotesResolved {
        try await resolve([reference], kind: kind)[0].get()
    }

    /// The UUIDs of the rows with these scripting ids, for naming them in a result.
    ///
    /// This never throws: a result that can't carry the UUID carries the scripting id alone.
    /// With `awaitingNew`, a row that is not there yet is looked for again for about a second,
    /// because the database can lag behind Notes by a moment after a script writes.
    func uuids(forResultIDs ids: [String], awaitingNew: Bool = false) async -> [String: String] {
        let wanted = Array(Set(ids.filter { NotesScriptID($0) != nil }))
        guard !wanted.isEmpty else { return [:] }
        var found: [String: String] = [:]
        for attempt in 0 ..< (awaitingNew ? 5 : 1) {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            guard let current = try? await uuids(forScriptIDs: wanted.filter { found[$0] == nil }) else { break }
            found.merge(current) { $1 }
            if found.count == wanted.count { break }
        }
        return found
    }
}

enum NotesIdentifiers {
    /// The fields that name a note or folder: `identifier` is the UUID when it is known,
    /// and `scriptIdentifier` is the id that the Notes app uses.
    static func fields(_ scriptID: String, uuids: [String: String], uuid known: String? = nil) -> [String: Value] {
        var fields: [String: Value] = ["scriptIdentifier": .string(scriptID)]
        if let uuid = known ?? uuids[scriptID] { fields["identifier"] = .string(uuid) }
        return fields
    }

    /// The same, with a prefix on each field name, for a related note or folder.
    static func fields(
        _ scriptID: String,
        uuids: [String: String],
        prefix: String
    ) -> [String: Value] {
        var fields: [String: Value] = [:]
        for (key, value) in Self.fields(scriptID, uuids: uuids) {
            fields[prefix + key.prefix(1).uppercased() + key.dropFirst()] = value
        }
        return fields
    }
}

// MARK: - Tagging read results

/// Adds the scripting id to the notes and folders in a result of the tools that read the database.
///
/// Those tools name a note or folder by `@id`, which is its UUID. Every object with an `@id` that the
/// database knows as a note or folder also gets `identifier` (the same UUID) and `scriptIdentifier`.
enum NotesScriptIdentifierAnnotator {
    /// The `@id` of every object in the result.
    static func ids(in value: Value) -> [String] {
        var found: Set<String> = []
        func visit(_ value: Value) {
            switch value {
            case .object(let object):
                if case .string(let id)? = object["@id"] { found.insert(id) }
                object.values.forEach(visit)
            case .array(let array):
                array.forEach(visit)
            default:
                break
            }
        }
        visit(value)
        return Array(found)
    }

    /// - Parameter scriptIDs: The scripting id of each known row, keyed by its uppercased UUID.
    static func annotate(_ value: Value, scriptIDs: [String: String]) -> Value {
        switch value {
        case .object(var object):
            object = object.mapValues { annotate($0, scriptIDs: scriptIDs) }
            if case .string(let id)? = object["@id"], let scriptID = scriptIDs[id.uppercased()] {
                object["identifier"] = .string(id)
                object["scriptIdentifier"] = .string(scriptID)
            }
            return .object(object)
        case .array(let array):
            return .array(array.map { annotate($0, scriptIDs: scriptIDs) })
        default:
            return value
        }
    }
}
