import Foundation
import Darwin
import os

/// Enforces restrictive filesystem permissions (0700 directories, 0600 files)
/// on app-owned Application Support directories, SQLite databases (including WAL/SHM),
/// and created cost/plan JSONs.
///
/// NOTE: Filesystem permissions restrict access to the local macOS user account.
/// They do NOT provide application-level encryption at rest.
public enum PrivacyFileProtection {
    public static let directoryPermissions: NSNumber = 0o700
    public static let filePermissions: NSNumber = 0o600

    private static let logger = Logger(subsystem: "com.vinz.codenotch", category: "privacy")

    /// Sets directory permissions to 0700 (rwx------) for the given directory and its
    /// parent app directory (e.g. both `Application Support/Codenotch` and `Application Support/Codenotch/costs`).
    @discardableResult
    public static func secureDirectory(at url: URL) throws -> Bool {
        let fm = FileManager.default
        let standardPath = url.standardizedFileURL

        var dirsToSecure: [URL] = []
        if standardPath.pathComponents.contains("Codenotch") {
            var curr = standardPath
            while curr.pathComponents.count > 1 {
                dirsToSecure.append(curr)
                if curr.lastPathComponent == "Codenotch" {
                    break
                }
                let parent = curr.deletingLastPathComponent()
                if parent == curr { break }
                curr = parent
            }
        } else {
            dirsToSecure.append(standardPath)
        }

        // Apply from top down (legacy Codenotch -> costs)
        for dir in dirsToSecure.reversed() {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: directoryPermissions])
            }
            try fm.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: dir.path)
        }
        return true
    }

    /// Sets file permissions to 0600 (rw-------).
    @discardableResult
    public static func secureFile(at url: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        try fm.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
        return true
    }

    /// Writes data atomically using initial creation permissions 0600 (rw-------)
    /// to eliminate the window where a newly created file might otherwise have permissive umask.
    public static func writeAtomically(data: Data, to destinationURL: URL, permissions: NSNumber = filePermissions) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try secureDirectory(at: parentDir)

        let tempURL = parentDir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let descriptor = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions.uint16Value))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(tempURL.path, destinationURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try secureFile(at: destinationURL)
    }

    /// Secures an SQLite database file and companion WAL / SHM files if present,
    /// as well as the enclosing directories.
    @discardableResult
    public static func secureDatabase(at url: URL) throws -> [URL] {
        var secured: [URL] = []
        try secureDirectory(at: url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            try secureFile(at: url)
            secured.append(url)
        }
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: companion.path) {
                try secureFile(at: companion)
                secured.append(companion)
            }
        }
        return secured
    }

    /// Verifies POSIX permissions on an item.
    public static func currentPermissions(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perms = attrs[.posixPermissions] as? NSNumber else { return nil }
        return perms.intValue
    }
}
