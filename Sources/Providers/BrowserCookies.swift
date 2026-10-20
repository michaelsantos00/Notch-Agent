import CommonCrypto
import Foundation
import SQLite3

/// One site's sign-in cookie, read out of a browser already signed in to it.
///
/// For a provider that publishes its figures only on a web page — Ollama's
/// session and weekly percentages, since its API went to request counts — the
/// browser the user already signed in with is the honest credential: NotchAgent
/// never signs in itself, and never loads the site.
///
/// Read-only throughout. Only the named cookie of the exact host is ever read,
/// it is held in memory by the caller, and it is sent nowhere but that host.
/// Each browser keeps cookies its own way:
///
/// - Safari: one binary file, unencrypted, inside Safari's container — which
///   macOS guards with Full Disk Access.
/// - Chromium (Chrome, Edge, Brave, Arc, Vivaldi, Comet, Dia, Opera): SQLite per
///   profile, the value AES-encrypted with a key kept in the login keychain as
///   "<Browser> Safe Storage". Reading that key raises the keychain dialogue,
///   so it is read only for the browser actually chosen, never to list them.
/// - Firefox and Zen: SQLite per profile, unencrypted.
enum BrowserCookies {
    enum Engine: Equatable, Sendable {
        case safari
        /// Keychain item holding the password the cookie key is derived from.
        case chromium(service: String, account: String)
        case firefox
    }

    struct Browser: Equatable, Sendable {
        let id: String
        let name: String
        let engine: Engine
        /// Under ~/Library/Application Support, except Safari's (absolute
        /// within the home folder, see `safariCookieFiles`).
        let directory: String
    }

    static let browsers: [Browser] = [
        Browser(id: "safari", name: "Safari", engine: .safari, directory: ""),
        chromium("chrome", "Chrome", "Google/Chrome", key: "Chrome"),
        chromium("edge", "Edge", "Microsoft Edge", key: "Microsoft Edge"),
        chromium("brave", "Brave", "BraveSoftware/Brave-Browser", key: "Brave"),
        chromium("arc", "Arc", "Arc/User Data", key: "Arc"),
        chromium("vivaldi", "Vivaldi", "Vivaldi", key: "Vivaldi"),
        chromium("comet", "Comet", "Comet", key: "Comet"),
        chromium("dia", "Dia", "Dia/User Data", key: "Dia"),
        chromium("opera", "Opera", "com.operasoftware.Opera", key: "Opera"),
        chromium("chromium", "Chromium", "Chromium", key: "Chromium"),
        Browser(id: "firefox", name: "Firefox", engine: .firefox, directory: "Firefox/Profiles"),
        Browser(id: "zen", name: "Zen", engine: .firefox, directory: "zen/Profiles"),
    ]

    private static func chromium(_ id: String, _ name: String, _ directory: String, key: String) -> Browser {
        Browser(id: id, name: name, engine: .chromium(service: "\(key) Safe Storage", account: key),
                directory: directory)
    }

    /// One cookie database: a browser, or one profile of it.
    struct Store: Identifiable, Equatable, Sendable {
        let browser: Browser
        /// The profile's folder name; nil for Safari, which has one store.
        let profile: String?
        let file: URL
        /// The name the browser shows for the profile, where it records one.
        var profileName: String?

        /// Stable across launches, so a choice can be saved: "chrome/Profile 1".
        var id: String { profile.map { "\(browser.id)/\($0)" } ?? browser.id }

        var displayName: String {
            guard let profile else { return browser.name }
            if let profileName, profileName != profile { return "\(browser.name) — \(profileName)" }
            return "\(browser.name) — \(profile)"
        }
    }

    /// A signed-in session found in a store: where, and until when. The value
    /// itself is not read here — for Chromium that would take the keychain.
    struct Session: Equatable, Sendable {
        let store: Store
        let expires: Date?
    }

    enum ReadError: Error, Equatable {
        /// Safari's container is behind Full Disk Access.
        case needsFullDiskAccess
        /// The keychain refused the browser's key, or it is missing.
        case keyUnavailable
        case notFound
    }

    // MARK: - Finding

    /// Every cookie store on this Mac, signed in to anything or not.
    static func stores(home: URL) -> [Store] {
        let support = home.appendingPathComponent("Library/Application Support")
        return browsers.flatMap { browser -> [Store] in
            switch browser.engine {
            case .safari:
                return safariCookieFiles(home: home)
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                    .prefix(1)
                    .map { Store(browser: browser, profile: nil, file: $0) }
            case .chromium:
                let root = support.appendingPathComponent(browser.directory)
                let names = chromiumProfileNames(root: root)
                return profileFolders(in: root).compactMap { folder in
                    guard !["System Profile", "Guest Profile"].contains(folder) else { return nil }
                    let base = root.appendingPathComponent(folder)
                    let file = [base.appendingPathComponent("Network/Cookies"), base.appendingPathComponent("Cookies")]
                        .first { FileManager.default.fileExists(atPath: $0.path) }
                    return file.map { Store(browser: browser, profile: folder, file: $0, profileName: names[folder]) }
                }
            case .firefox:
                let root = support.appendingPathComponent(browser.directory)
                return profileFolders(in: root).compactMap { folder in
                    let file = root.appendingPathComponent(folder).appendingPathComponent("cookies.sqlite")
                    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                    return Store(browser: browser, profile: folder, file: file)
                }
            }
        }
    }

    /// The stores holding `name` for exactly `host`, with when each expires.
    /// Never touches the keychain, so it is safe to call to fill a menu.
    static func sessions(named name: String, host: String, home: URL) -> [Session] {
        stores(home: home).compactMap { store in
            switch store.browser.engine {
            case .safari:
                guard let data = try? Data(contentsOf: store.file) else { return nil }
                return safariCookies(in: data)
                    .first { matches($0.host, host) && $0.name == name }
                    .map { Session(store: store, expires: $0.expires) }
            case .chromium:
                let rows = query(store.file, "SELECT host_key, expires_utc FROM cookies WHERE name = ?1", bind: name)
                return rows.first { matches($0[0], host) }.map {
                    Session(store: store, expires: Int64($0[1]).flatMap(chromiumDate))
                }
            case .firefox:
                let rows = query(store.file, "SELECT host, expiry FROM moz_cookies WHERE name = ?1", bind: name)
                return rows.first { matches($0[0], host) }.map {
                    Session(store: store, expires: Int64($0[1]).map(firefoxDate))
                }
            }
        }
    }

    /// Safari keeps cookies but macOS will not let this app open them. Asked by
    /// opening the file: the permission bits say yes either way, because Full
    /// Disk Access is enforced above them.
    static func safariNeedsFullDiskAccess(home: URL) -> Bool {
        guard let file = safariCookieFiles(home: home)
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return true }
        try? handle.close()
        return false
    }

    /// The session that lasts longest, among those not yet expired. What
    /// "Automatic" means: the browser most recently signed in, in practice.
    static func freshest(_ sessions: [Session], now: Date = Date()) -> Session? {
        sessions
            .filter { ($0.expires ?? .distantFuture) > now }
            .max { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }

    // MARK: - Reading

    /// The cookie's value. `password` is asked only for a Chromium store, with
    /// the keychain item to read — the one step that can raise a dialogue.
    static func value(named name: String, host: String, in store: Store,
                      password: (Engine) throws -> String) throws -> String {
        switch store.browser.engine {
        case .safari:
            let data: Data
            do { data = try Data(contentsOf: store.file) } catch {
                throw (error as NSError).code == NSFileReadNoPermissionError
                    ? ReadError.needsFullDiskAccess : ReadError.notFound
            }
            guard let cookie = safariCookies(in: data).first(where: { matches($0.host, host) && $0.name == name })
            else { throw ReadError.notFound }
            return cookie.value
        case .chromium:
            let rows = query(store.file,
                             "SELECT host_key, value, hex(encrypted_value) FROM cookies WHERE name = ?1",
                             bind: name)
            guard let row = rows.first(where: { matches($0[0], host) }) else { throw ReadError.notFound }
            if !row[1].isEmpty { return row[1] }
            guard let blob = Data(hexString: row[2]) else { throw ReadError.notFound }
            let version = Int(query(store.file, "SELECT value FROM meta WHERE key = 'version'").first?.first ?? "") ?? 0
            guard let value = decryptChromium(blob, password: try password(store.browser.engine),
                                               metaVersion: version)
            else { throw ReadError.keyUnavailable }
            return value
        case .firefox:
            let rows = query(store.file, "SELECT host, value FROM moz_cookies WHERE name = ?1", bind: name)
            guard let row = rows.first(where: { matches($0[0], host) }) else { throw ReadError.notFound }
            return row[1]
        }
    }

    /// The Chromium cookie password from the login keychain.
    static func keychainPassword(for engine: Engine) throws -> String {
        guard case .chromium(let service, let account) = engine,
              let password = KeychainItem.read(service: service, account: account)
        else { throw ReadError.keyUnavailable }
        return password
    }

    // MARK: - Formats

    /// Chromium on macOS: `v10`, then AES-128-CBC under a key derived from the
    /// keychain password with PBKDF2-SHA1 ("saltysalt", 1003 rounds), IV of
    /// sixteen spaces. From database version 24 the plaintext starts with a
    /// SHA-256 of the host, which is not part of the value.
    static func decryptChromium(_ blob: Data, password: String, metaVersion: Int) -> String? {
        guard blob.starts(with: Data("v10".utf8)) else { return nil }
        let ciphertext = blob.dropFirst(3)

        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = password.withCString { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, strlen(pw), salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, ciphertext.count, &out, out.count, &written)
        }
        guard status == kCCSuccess else { return nil }

        var plain = Data(out.prefix(written))
        if metaVersion >= 24 {
            guard plain.count >= 32 else { return nil }
            plain = plain.dropFirst(32)
        }
        return String(data: plain, encoding: .utf8)
    }

    struct SafariCookie: Equatable {
        let host: String
        let name: String
        let value: String
        let expires: Date
    }

    /// Safari's `Cookies.binarycookies`: "cook", a big-endian page count and
    /// page sizes, then pages of little-endian cookie records whose strings are
    /// found by offset from the record's own start. Anything malformed is
    /// skipped rather than trusted.
    static func safariCookies(in data: Data) -> [SafariCookie] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<4]) == Array("cook".utf8) else { return [] }
        let pages = Int(be32(bytes, 4))
        var sizes: [Int] = []
        for index in 0..<pages {
            let at = 8 + 4 * index
            guard at + 4 <= bytes.count else { return [] }
            sizes.append(Int(be32(bytes, at)))
        }

        var cookies: [SafariCookie] = []
        var pageStart = 8 + 4 * pages
        for size in sizes {
            guard size > 8, pageStart + size <= bytes.count else { break }
            let page = Array(bytes[pageStart..<(pageStart + size)])
            pageStart += size
            let count = Int(le32(page, 4))
            for index in 0..<count {
                let at = 8 + 4 * index
                guard at + 4 <= page.count else { break }
                let start = Int(le32(page, at))
                guard start + 56 <= page.count else { continue }
                let record = Array(page[start...])
                func string(_ offsetAt: Int) -> String? {
                    let offset = Int(le32(record, offsetAt))
                    guard offset < record.count,
                          let end = record[offset...].firstIndex(of: 0) else { return nil }
                    return String(decoding: record[offset..<end], as: UTF8.self)
                }
                guard let host = string(16), let name = string(20), let value = string(28) else { continue }
                let expiry = Double(bitPattern: le64(record, 40))
                cookies.append(SafariCookie(host: host, name: name, value: value,
                                            expires: Date(timeIntervalSinceReferenceDate: expiry)))
            }
        }
        return cookies
    }

    // MARK: - Helpers

    /// Exact host, or its leading-dot domain form — never a lookalike.
    static func matches(_ cookieHost: String, _ host: String) -> Bool {
        cookieHost == host || cookieHost == ".\(host)"
    }

    /// Microseconds since 1601, Chromium's epoch.
    private static func chromiumDate(_ micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    /// Firefox moved from seconds to milliseconds; both are still in the wild.
    private static func firefoxDate(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: value > 100_000_000_000 ? Double(value) / 1000 : Double(value))
    }

    private static func safariCookieFiles(home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
         home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")]
    }

    private static func profileFolders(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    /// Chromium records each profile's display name in "Local State".
    private static func chromiumProfileNames(root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    /// Queries a copy of the database, never the original. A running browser
    /// holds its cookie store locked and keeps recent writes in a write-ahead
    /// log; a copy taken with its sidecars sees those writes and locks nothing.
    private static func query(_ file: URL, _ sql: String, bind: String? = nil) -> [[String]] {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchagent-cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let copy = scratch.appendingPathComponent("db")
            try FileManager.default.copyItem(at: file, to: copy)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: file.path + suffix)
                if FileManager.default.fileExists(atPath: side.path) {
                    try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return []
            }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            if let bind {
                sqlite3_bind_text(statement, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            var rows: [[String]] = []
            let columns = sqlite3_column_count(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((0..<columns).map { index in
                    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
                })
            }
            return rows
        } catch {
            return []
        }
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func le64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<(at + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
