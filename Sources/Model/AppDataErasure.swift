import Foundation

/// A barrier for late archive writes from cancelled provider requests.
enum PersistentWrites {
    private static let lock = NSRecursiveLock()
    private static var suspended = false

    static var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended
    }

    static func perform(_ write: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else { return }
        write()
    }

    static func suspend() {
        lock.lock()
        suspended = true
        lock.unlock()
    }

    static func resumeForTesting() {
        precondition(Runtime.isUnderTest)
        lock.lock()
        suspended = false
        lock.unlock()
    }
}

@MainActor
enum AppDataErasure {
    static var shutdown: (() async throws -> Void)?

    static func erase() async -> Preferences.EraseResult {
        guard let shutdown else {
            var result = Preferences.EraseResult()
            result.success = false
            result.failedPaths.append((path: "shutdown", error: "Application shutdown is unavailable."))
            return result
        }
        PersistentWrites.suspend()
        return await Preferences.eraseAllData(quiesceWriters: shutdown)
    }
}
