import SQLite3
import XCTest
@testable import NotchAgent

/// Ollama read through a browser's ollama.com sign-in, instead of the API key.
final class OllamaBrowserSourceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        OllamaPageStub.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private let page = """
    <a href="/signout">Sign out</a>
    <div data-usage-track aria-label="Session usage 12.5% used"></div>
    <div data-time="2026-10-20T16:00:00Z"></div>
    <div data-usage-track aria-label="Weekly usage 40% used">
      <button data-usage-segment data-model="glm-5.3" data-requests="7"></button>
    </div>
    <div data-time="2026-10-26T00:00:00Z"></div>
    """

    private func provider(store: String = OllamaCloudSource.automatic,
                          password: @escaping @Sendable (BrowserCookies.Engine) throws -> String = { _ in
                              XCTFail("no keychain read expected"); return "" }) -> OllamaProvider {
        OllamaProvider(session: OllamaPageStub.session(), home: home,
                       source: { OllamaCloudSource(usage: .browser, cookieStore: store) },
                       password: password)
    }

    func testTheSignedInBrowserIsUsedForThePercentages() async throws {
        try firefox("abc", value: "firefox-session")
        OllamaPageStub.respond(200, page)

        let snapshot = try await provider().fetchSnapshot()

        XCTAssertEqual(snapshot.windows.first { $0.id == "session" }?.usedFraction ?? -1, 0.125, accuracy: 1e-9)
        XCTAssertEqual(snapshot.windows.first { $0.id == "weekly" }?.usedFraction ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(snapshot.headlineID, "session")
        XCTAssertEqual(snapshot.weeklyID, "weekly")
        XCTAssertEqual(snapshot.fidelity, .official)

        let request = try XCTUnwrap(OllamaPageStub.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://ollama.com/settings"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Secure-session=firefox-session")
    }

    func testNoSignedInBrowserAsksForSignInWithoutARequest() async {
        await assertThrows(UsageProviderError.needsAuth) { try await self.provider().fetchSnapshot() }
        XCTAssertTrue(OllamaPageStub.requests.isEmpty)
    }

    /// A browser picked by hand is the one used — another being signed in is
    /// not a reason to read that one instead.
    func testAPinnedBrowserIsRespected() async throws {
        try firefox("other", value: "x")
        await assertThrows(UsageProviderError.needsAuth) {
            try await self.provider(store: "chrome/Default").fetchSnapshot()
        }
        XCTAssertTrue(OllamaPageStub.requests.isEmpty)
    }

    /// The cookie aged out: the page comes back signed out.
    func testASignedOutPageAsksForSignIn() async throws {
        try firefox("abc", value: "stale")
        OllamaPageStub.respond(200, #"<a href="https://signin.ollama.com">Sign in</a>"#)
        await assertThrows(UsageProviderError.needsAuth) { try await self.provider().fetchSnapshot() }
    }

    /// Declining the keychain dialogue must not bring it back every minute.
    func testARefusedKeyIsNotAskedForAgain() async throws {
        try chromium()
        let asks = Counter()
        let provider = provider(password: { _ in
            asks.increment()
            throw BrowserCookies.ReadError.keyUnavailable
        })

        await assertThrows(UsageProviderError.accessDenied) { try await provider.fetchSnapshot() }
        await assertThrows(UsageProviderError.accessDenied) { try await provider.fetchSnapshot() }
        XCTAssertEqual(asks.value, 1)

        // "Allow access…" is the deliberate retry.
        provider.forgetCachedCredential()
        await assertThrows(UsageProviderError.accessDenied) { try await provider.fetchSnapshot() }
        XCTAssertEqual(asks.value, 2)
    }

    // MARK: - Fixtures

    private func firefox(_ profile: String, value: String) throws {
        try sqlite("Library/Application Support/Firefox/Profiles/\(profile)/cookies.sqlite", [
            "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, expiry INTEGER)",
            "INSERT INTO moz_cookies VALUES ('ollama.com', '__Secure-session', '\(value)', 4102444800000)",
        ])
    }

    private func chromium() throws {
        try sqlite("Library/Application Support/Google/Chrome/Default/Cookies", [
            "CREATE TABLE meta (key TEXT, value TEXT)",
            "INSERT INTO meta VALUES ('version', '24')",
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER)",
            "INSERT INTO cookies VALUES ('ollama.com', '__Secure-session', '', X'763130AA', 0)",
        ])
    }

    private func sqlite(_ relative: String, _ statements: [String]) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
    }

    private func assertThrows(_ expected: UsageProviderError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: @escaping () async throws -> ProviderSnapshot) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as UsageProviderError {
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class OllamaPageStub: URLProtocol {
    private static let lock = NSLock()
    private static var reply: (Int, Data) = (500, Data())
    private(set) static var requests: [URLRequest] = []

    static func reset() { lock.lock(); requests = []; reply = (500, Data()); lock.unlock() }
    static func respond(_ status: Int, _ body: String) { lock.lock(); reply = (status, Data(body.utf8)); lock.unlock() }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaPageStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let (status, data) = Self.reply
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                              httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
