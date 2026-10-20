import SQLite3
import XCTest
@testable import NotchAgent

/// Reading one site's sign-in cookie out of the browsers on this Mac — each
/// keeps them its own way: Safari in a binary file, Chromium in SQLite with the
/// values encrypted, Firefox in plain SQLite.
final class BrowserCookiesTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Chromium decryption

    /// Computed outside Swift: PBKDF2-SHA1("test-safe-storage-password",
    /// "saltysalt", 1003) → AES-128-CBC with a 16-space IV, over
    /// SHA256("ollama.com") + "session-cookie-value", behind the `v10` marker.
    private let password = "test-safe-storage-password"
    private let modernBlob = "763130" + "d96d0b1fbef85b808a466d6b199f6a9686155a14709ab542e48b5d661c57cd4fc718d5153f00db1e779cb7a1cd31642691e63637c4c14795b9e2b3a39eddb2bb"
    private let legacyBlob = "763130" + "daa1f51916f3f9ea320ed72860a72bcf"

    /// From database version 24 Chromium prefixes each value with a hash of
    /// its host; it is not part of the cookie.
    func testChromiumValuesLoseTheirHostHashFromVersion24() {
        XCTAssertEqual(BrowserCookies.decryptChromium(Data(hexString: modernBlob)!, password: password, metaVersion: 24),
                       "session-cookie-value")
    }

    func testOlderChromiumValuesAreTakenWhole() {
        XCTAssertEqual(BrowserCookies.decryptChromium(Data(hexString: legacyBlob)!, password: password, metaVersion: 23),
                       "legacy-value")
    }

    func testTheWrongPasswordYieldsNothing() {
        XCTAssertNil(BrowserCookies.decryptChromium(Data(hexString: modernBlob)!, password: "wrong", metaVersion: 24))
    }

    // MARK: - Safari

    func testSafariBinaryCookiesAreRead() {
        let data = SafariCookieFile.make([
            ("ollama.com", "__Secure-session", "safari-value", 800_000_000),
            ("example.com", "other", "x", 800_000_000),
        ])
        let cookies = BrowserCookies.safariCookies(in: data)
        XCTAssertEqual(cookies.map(\.name), ["__Secure-session", "other"])
        XCTAssertEqual(cookies.first?.value, "safari-value")
        XCTAssertEqual(cookies.first?.host, "ollama.com")
        XCTAssertEqual(cookies.first?.expires, Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    func testAFileThatIsNotSafarisYieldsNothing() {
        XCTAssertTrue(BrowserCookies.safariCookies(in: Data("not cookies".utf8)).isEmpty)
    }

    // MARK: - Finding and reading, end to end

    func testAChromeProfileIsFoundAndDecrypted() throws {
        let expires = Date(timeIntervalSince1970: 1_900_000_000)
        try makeChromium(at: "Library/Application Support/Google/Chrome/Profile 1/Cookies",
                         host: "ollama.com", blobHex: modernBlob, expires: expires)

        let found = BrowserCookies.sessions(named: "__Secure-session", host: "ollama.com", home: home)
        let chrome = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(chrome.store.id, "chrome/Profile 1")
        XCTAssertEqual(chrome.store.displayName, "Chrome — Profile 1")
        XCTAssertEqual(chrome.expires, expires)

        let value = try BrowserCookies.value(named: "__Secure-session", host: "ollama.com",
                                             in: chrome.store, password: { _ in self.password })
        XCTAssertEqual(value, "session-cookie-value")
    }

    /// Finding which browsers are signed in must not ask for the keychain —
    /// only reading the chosen one's value may.
    func testFindingSessionsNeverAsksForTheKey() throws {
        try makeChromium(at: "Library/Application Support/Google/Chrome/Default/Cookies",
                         host: "ollama.com", blobHex: modernBlob, expires: .distantFuture)
        let found = BrowserCookies.sessions(named: "__Secure-session", host: "ollama.com", home: home)
        XCTAssertEqual(found.count, 1, "sessions() has no password to ask with, by construction")
    }

    func testAFirefoxProfileIsFoundAndReadWithoutAKey() throws {
        let profile = "Library/Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite"
        try makeFirefox(at: profile, host: ".ollama.com", value: "firefox-value",
                        expiryMilliseconds: 1_900_000_000_000)

        let found = try XCTUnwrap(BrowserCookies.sessions(named: "__Secure-session", host: "ollama.com", home: home).first)
        XCTAssertEqual(found.store.id, "firefox/abc.default-release")
        XCTAssertEqual(found.expires, Date(timeIntervalSince1970: 1_900_000_000))

        let value = try BrowserCookies.value(named: "__Secure-session", host: "ollama.com", in: found.store,
                                             password: { _ in XCTFail("Firefox needs no key"); return "" })
        XCTAssertEqual(value, "firefox-value")
    }

    /// A lookalike host must never match: the cookie is ollama.com's alone.
    func testOnlyTheExactSiteMatches() throws {
        try makeFirefox(at: "Library/Application Support/Firefox/Profiles/p/cookies.sqlite",
                        host: "notollama.com", value: "x", expiryMilliseconds: 1_900_000_000_000)
        XCTAssertTrue(BrowserCookies.sessions(named: "__Secure-session", host: "ollama.com", home: home).isEmpty)
    }

    // MARK: - Automatic choice

    func testAutomaticTakesTheSignInThatLastsLongest() throws {
        try makeFirefox(at: "Library/Application Support/Firefox/Profiles/old/cookies.sqlite",
                        host: "ollama.com", value: "a", expiryMilliseconds: 1_850_000_000_000)
        try makeFirefox(at: "Library/Application Support/Firefox/Profiles/new/cookies.sqlite",
                        host: "ollama.com", value: "b", expiryMilliseconds: 1_900_000_000_000)
        let found = BrowserCookies.sessions(named: "__Secure-session", host: "ollama.com", home: home)
        XCTAssertEqual(BrowserCookies.freshest(found, now: Date(timeIntervalSince1970: 1_800_000_000))?.store.id,
                       "firefox/new")
    }

    func testAutomaticIgnoresExpiredSignIns() throws {
        try makeFirefox(at: "Library/Application Support/Firefox/Profiles/gone/cookies.sqlite",
                        host: "ollama.com", value: "a", expiryMilliseconds: 1_700_000_000_000)
        let found = BrowserCookies.sessions(named: "__Secure-session", host: "ollama.com", home: home)
        XCTAssertNil(BrowserCookies.freshest(found, now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    // MARK: - Fixtures

    private func makeChromium(at relative: String, host: String, blobHex: String, expires: Date) throws {
        let chromeEpochMicros = Int64((expires.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        try sqlite(at: relative, [
            "CREATE TABLE meta (key TEXT, value TEXT)",
            "INSERT INTO meta VALUES ('version', '24')",
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER)",
            "INSERT INTO cookies VALUES ('\(host)', '__Secure-session', '', X'\(blobHex)', \(chromeEpochMicros))",
        ])
    }

    private func makeFirefox(at relative: String, host: String, value: String, expiryMilliseconds: Int64) throws {
        try sqlite(at: relative, [
            "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, expiry INTEGER)",
            "INSERT INTO moz_cookies VALUES ('\(host)', '__Secure-session', '\(value)', \(expiryMilliseconds))",
        ])
    }

    private func sqlite(at relative: String, _ statements: [String]) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
    }
}

/// Writes Safari's `Cookies.binarycookies` layout: a big-endian file header
/// and page table, then little-endian pages of cookie records whose strings
/// are found by offset from the record's start.
private enum SafariCookieFile {
    static func make(_ cookies: [(host: String, name: String, value: String, expires: Double)]) -> Data {
        var page = Data()
        page.append(le32(0x0000_0100))
        page.append(le32(UInt32(cookies.count)))
        let headerSize = 8 + 4 * cookies.count + 4
        var records: [Data] = cookies.map(record)
        var offsets: [Int] = []
        var cursor = headerSize
        for r in records { offsets.append(cursor); cursor += r.count }
        for o in offsets { page.append(le32(UInt32(o))) }
        page.append(le32(0))
        for r in records { page.append(r) }
        records.removeAll()

        var file = Data("cook".utf8)
        file.append(be32(1))
        file.append(be32(UInt32(page.count)))
        file.append(page)
        return file
    }

    private static func record(_ c: (host: String, name: String, value: String, expires: Double)) -> Data {
        let strings = [c.host, c.name, "/", c.value].map { Data($0.utf8) + Data([0]) }
        let fixed = 56
        var offsets: [Int] = []
        var cursor = fixed
        for s in strings { offsets.append(cursor); cursor += s.count }
        var r = Data()
        r.append(le32(UInt32(cursor)))   // size
        r.append(le32(0))                // unknown
        r.append(le32(0))                // flags
        r.append(le32(0))                // unknown
        for o in offsets { r.append(le32(UInt32(o))) }  // url, name, path, value
        r.append(le32(0)); r.append(le32(0))            // comment, end of header
        r.append(le64(c.expires)); r.append(le64(c.expires))
        for s in strings { r.append(s) }
        return r
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func le64(_ v: Double) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }
}
