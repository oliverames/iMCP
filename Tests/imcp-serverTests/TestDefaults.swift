import Foundation

/// Throwaway `UserDefaults` suites for tests.
///
/// `removePersistentDomain(forName:)` empties a suite but leaves its plist in
/// `~/Library/Preferences`, so every test run used to leave hundreds of files there.
/// A suite made here is emptied and its file deleted when the test process exits.
/// An exit handler is used rather than a test observer, because XCTest only lets
/// observers register on the main thread and suites are made from any thread.
enum TestDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: Set<String> = []
    nonisolated(unsafe) private static var registered = false

    /// The suite with this name, removed with its file when the run ends.
    /// Use it wherever a test would call `UserDefaults(suiteName:)`.
    static func suite(named name: String) -> UserDefaults? {
        lock.withLock {
            names.insert(name)
            if !registered {
                registered = true
                atexit { TestDefaults.removeAll() }
            }
        }
        return UserDefaults(suiteName: name)
    }

    /// Empties a suite and deletes its plist.
    static func remove(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
    }

    fileprivate static func removeAll() {
        let all = lock.withLock {
            defer { names.removeAll() }
            return names
        }
        for name in all { remove(name) }
    }
}
