import SQLite3
import XCTest
@testable import NotchAgent

final class ProviderIntegrationRegressionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testReadOnlyCheckpointedWALDatabaseCanBeQueried() throws {
        let files = FileManager.default
        let directory = try temporaryDirectory()
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? files.removeItem(at: directory)
        }
        let path = directory.appendingPathComponent("probe #1?.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        let setup = "PRAGMA journal_mode=WAL; CREATE TABLE probe (value TEXT); INSERT INTO probe VALUES ('present');"
        XCTAssertEqual(sqlite3_exec(writer, setup, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        for suffix in ["-wal", "-shm"] {
            let sidecar = path.path + suffix
            if files.fileExists(atPath: sidecar) { try files.removeItem(atPath: sidecar) }
        }
        try files.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        let db = try XCTUnwrap(SQLiteStore.open(path))
        defer { sqlite3_close(db) }
        XCTAssertEqual(SQLiteStore.rows(in: db, sql: "SELECT value FROM probe"), ["present"])
    }

    func testSQLiteReaderSeesUncheckpointedWALWrites() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("live.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        let setup = "PRAGMA journal_mode=WAL; CREATE TABLE probe (value TEXT); INSERT INTO probe VALUES ('live');"
        XCTAssertEqual(sqlite3_exec(writer, setup, nil, nil, nil), SQLITE_OK)
        let db = try XCTUnwrap(SQLiteStore.open(path))
        defer { sqlite3_close(db) }
        XCTAssertEqual(SQLiteStore.rows(in: db, sql: "SELECT value FROM probe"), ["live"])
    }

    func testCodexWeeklyPrimaryDoesNotPromoteSparkOrOtherPeriods() {
        let week: TimeInterval = 7 * 86400
        let primary = LimitWindow(id: "primary", label: "Weekly", usedFraction: 0.4, duration: week)
        let spark = LimitWindow(id: "spark-secondary", group: "Spark", label: "Weekly", usedFraction: 1, duration: week)
        let monthly = LimitWindow(id: "secondary", label: "Monthly", usedFraction: 0.2, duration: 30 * 86400)
        XCTAssertEqual(CodexUsage.weeklyID(in: [primary, spark]), "primary")
        XCTAssertNil(CodexUsage.weeklyID(in: [spark, monthly]))
    }

    func testOllamaAPIBalanceReportsMonthlyUsageAndWalletIndependently() throws {
        let data = Data(#"""
        {"included":{"allowance_usd":"60.00","balance_usd":"52.50","period":{
            "from":"2026-11-01T00:00:00Z","until":"2026-12-01T00:00:00Z"}},
         "purchased":{"balance_usd":5.25}}
        """#.utf8)
        let reading = try OllamaUsage.balance(from: data)
        XCTAssertEqual(reading.headlineID, "monthly")
        XCTAssertEqual(reading.windows.map(\.id), ["monthly", "credit-balance"])
        XCTAssertEqual(reading.windows[0].usedFraction, 0.125)
        XCTAssertEqual(reading.windows[0].duration, 30 * 86400)
        XCTAssertEqual(reading.windows[0].money?.remaining, 52.50)
        XCTAssertNil(reading.windows[1].usedFraction)
    }

    func testOllamaAPIBalanceRetainsLegacyWindowsAndMeasuredZero() throws {
        let data = Data(#"{"included":{"session":{"remaining_percent":100},"weekly":{"remaining_percent":75}}}"#.utf8)
        let reading = try OllamaUsage.balance(from: data)
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(reading.windows.map(\.usedFraction), [0, 0.25])
    }

    func testOllamaBrowserMonthlyIncludedUsageAndWalletOnly() throws {
        let monthly = try OllamaWebUsage.parse(#"""
        <section><h2>Included usage</h2><div><span>Monthly usage</span><span>$7.50 of $60 used</span></div>
        <p data-time="2026-12-01T00:00:00Z">Resets in 8 days</p></section>
        """#)
        XCTAssertEqual(monthly.headlineID, "monthly")
        XCTAssertEqual(monthly.windows.first?.usedFraction, 0.125)
        XCTAssertNotNil(monthly.windows.first?.resetsAt)
        let free = try OllamaWebUsage.parse(#"""
        <section><h2>Included usage</h2><span>Free usage</span><div style="width: 25%"></div></section>
        """#)
        XCTAssertEqual(free.windows.first?.usedFraction, 0.25)
        let wallet = try OllamaWebUsage.parse(#"""
        <section><h2>Usage credits <span>Pro</span></h2>
        <div><span>$6.25</span></div><div><span>Monthly credits used</span><span>$3.75</span></div>
        <p>Refills to $60 in 8 days</p></section>
        """#)
        XCTAssertEqual(wallet.windows.map(\.id), ["credit-balance", "monthly-spend", "next-refill"])
        XCTAssertTrue(wallet.windows.allSatisfy { $0.usedFraction == nil })
    }

    func testCursorHookInstallationPreservesUserHooksAndRejectsMalformedSettings() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data(#"{"hooks":false}"#.utf8)
        try invalid.write(to: config)
        let hooks = CursorActivityHooks(home: home)
        let binary = home.appendingPathComponent("NotchAgent.app/Contents/MacOS/NotchAgent")
        XCTAssertThrowsError(try hooks.setInstalled(true, executable: binary))
        XCTAssertEqual(try Data(contentsOf: config), invalid)

        let original = Data(#"{"version":1,"hooks":{"stop":[{"command":"my-script"}]}}"#.utf8)
        try original.write(to: config)
        try hooks.setInstalled(true, executable: binary)
        XCTAssertTrue(hooks.isInstalled)
        try hooks.setInstalled(false, executable: binary)
        XCTAssertFalse(hooks.isInstalled)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let handlers = try XCTUnwrap(root["hooks"] as? [String: [[String: String]]])
        XCTAssertEqual(handlers["stop"], [["command": "my-script"]])
    }

    func testCursorHookKeepsOnlyStateAndSeparatesGenerations() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let hooks = CursorActivityHooks(home: home)
        try hooks.setInstalled(true, executable: home.appendingPathComponent("NotchAgent.app/Contents/MacOS/NotchAgent"))
        let now = Date()
        func send(_ event: String, _ generation: String, at: TimeInterval) throws {
            let payload = ["hook_event_name": event, "conversation_id": "chat-1", "generation_id": generation,
                           "status": "completed", "prompt": "private fixture", "user_email": "private@example.invalid"]
            hooks.record(try JSONEncoder().encode(payload), now: now.addingTimeInterval(at))
        }
        try send("beforeSubmitPrompt", "generation-1", at: 0)
        try send("beforeSubmitPrompt", "generation-2", at: 1)
        try send("stop", "generation-1", at: 2)
        XCTAssertEqual(hooks.sessions(now: now.addingTimeInterval(2), staleAfter: 900).map(\.state), [.busy])
        try send("stop", "generation-2", at: 3)
        try send("preToolUse", "generation-2", at: 4)
        XCTAssertEqual(hooks.sessions(now: now.addingTimeInterval(4), staleAfter: 900).map(\.state), [.success])
        let file = home.appendingPathComponent("Library/Caches/com.vinz.codenotch/CursorActivity/chat-1.json")
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("private"))
        XCTAssertTrue(hooks.sessions(now: now.addingTimeInterval(904), staleAfter: 900).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testOpenCodeTriesTheLiveSignInAfterARefusedGoKey() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeFallbackFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let provider = OpenCodeProvider(session: session, archive: UsageArchive(defaults: defaults)) {
            [OpenCodeCredentials.credential(from: "fixture-go", source: "fixture"),
             OpenCodeCredentials.credential(from: ["type": "oauth", "access": "fixture-oauth"], source: "fixture")]
                .compactMap { $0 }
        }
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.windows.map(\.id), ["rolling"])
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.4)
    }
}

private final class OpenCodeFallbackFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let isGo = url.path == "/zen/go/v1/usage"
        XCTAssertEqual(url.host, "opencode.ai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), isGo ? "Bearer fixture-go" : "Bearer fixture-oauth")
        if !isGo { XCTAssertEqual(url.path, "/inference/go/v1/usage") }
        let response = HTTPURLResponse(url: url, statusCode: isGo ? 403 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"usage":{"rolling":{"status":"ok","percent":40}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
