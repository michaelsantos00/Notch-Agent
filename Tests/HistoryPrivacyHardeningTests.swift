import XCTest
@testable import NotchAgent

@MainActor
final class HistoryPrivacyHardeningTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PersistentWrites.resumeForTesting()
        Costs.resumeForTesting()
        CostModels.stopAll()
        CostModels.preferences = nil
        CostModels.disconnected = []
        CostAccountStore.testAccountsOverride = nil
    }

    override func tearDown() {
        CostModels.stopAll()
        CostModels.preferences = nil
        CostModels.disconnected = []
        CostAccountStore.testAccountsOverride = nil
        PersistentWrites.resumeForTesting()
        Costs.resumeForTesting()
        super.tearDown()
    }

    func testRetentionDoesNotMoveBackwardsOrRestoreStalePathMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(CostStore(url: root.appendingPathComponent("agentcost-test.sqlite")))
        let now = Date()
        let cutoff = now.addingTimeInterval(-7 * 86400)
        try store.prune(olderThan: cutoff)
        try store.prune(olderThan: now.addingTimeInterval(-30 * 86400))
        XCTAssertEqual(store.metadata("retention_cutoff_ts"), String(Int(cutoff.timeIntervalSince1970)))
        let old = Int(now.addingTimeInterval(-20 * 86400).timeIntervalSince1970)
        let event = UsageEvent(ts: old, sessionId: "old", dedupeKey: "old", project: "old",
            cwd: "/fixture/private", branch: nil, model: "fixture", input: 10, output: 10,
            cacheRead: 0, cacheWrite: 0, ccVersion: nil)
        store.commit(events: [event], path: "/fixture/private/old.jsonl", inode: 1,
            size: 10, offset: 10, mtime: Double(old))
        XCTAssertEqual(store.stats().events, 0)
        XCTAssertNil(store.fileCursor("/fixture/private/old.jsonl"))
        store.quiesce()
    }

    // MARK: - 1. History OFF by default: no DB, no watcher, no read

    func testFailedShutdownDoesNotDeleteDataOrDefaults() async throws {
        let suite = "codenotch.erase-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("keep", forKey: "fixture")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owned = root.appendingPathComponent("Codenotch")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let file = owned.appendingPathComponent("fixture.json")
        try Data("keep".utf8).write(to: file)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var keychainCalls = 0
        let result = await Preferences.eraseAllData(bundleID: suite, libraryDirectory: root,
            appSupportDirectory: root, defaults: defaults,
            keychainDeleter: { _, _ in keychainCalls += 1 },
            quiesceWriters: { throw CocoaError(.userCancelled) })
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.writersQuiesced)
        XCTAssertFalse(result.defaultsCleared)
        XCTAssertEqual(defaults.string(forKey: "fixture"), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(keychainCalls, 0)
    }

    func testErasureBarrierRejectsLateArchiveWritesAndNetworkRequests() throws {
        let suite = "codenotch.erase-barrier.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            PersistentWrites.resumeForTesting()
            defaults.removePersistentDomain(forName: suite)
        }
        PersistentWrites.suspend()
        let archive = UsageArchive(defaults: defaults)
        archive.save([:])
        archive.saveBackoffUntil(Date().addingTimeInterval(60))
        XCTAssertNil(defaults.data(forKey: "lastGoodReadings"))
        XCTAssertNil(defaults.object(forKey: "backoffUntil"))
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "https://api.anthropic.com"), for: .claude))
    }

    func testHistoryOffDefault_NoDB_NoWatcher_NoRead() {
        let testDefaults = UserDefaults(suiteName: "com.vinz.codenotch.test.\(UUID().uuidString)")!
        let prefs = Preferences(defaults: testDefaults)

        // Verify default is strictly OFF for this private fork
        XCTAssertFalse(prefs.isHistoryIndexingEnabled, "History indexing must default to OFF")
        XCTAssertTrue(prefs.enabledHistoryAccountIDs.isEmpty, "Enabled history accounts must default to empty")

        // Configure CostModels with the injected preferences
        CostModels.configure(preferences: prefs, disconnected: [])

        // CostModels gate should block unapproved accounts
        XCTAssertFalse(CostModels.isHistoryEnabled(for: "claude"))
        XCTAssertNil(CostModels.model(for: "claude"), "CostModels.model must return nil when history is OFF")

        // Snapshot decoration must be a no-op
        let snap = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                    fidelity: .official, status: .ok, windows: [])
        let decorated = Costs.decorate(snap)
        XCTAssertNil(decorated.tokenUsage, "Snapshot must not be decorated when history is disabled")

        // CostModels.all must be empty
        XCTAssertTrue(CostModels.all.isEmpty, "CostModels.all must be empty when history is disabled")
    }

    // MARK: - 2. Enabled-account-only indexing with injected Preferences (no override)

    func testEnabledAccountOnlyIndexing_WithInjectedPreferences() {
        let testDefaults = UserDefaults(suiteName: "com.vinz.codenotch.test.\(UUID().uuidString)")!
        let prefs = Preferences(defaults: testDefaults)

        let accA = CostAccount(id: "claude-work", provider: "claude", name: "Work",
                               configDirectory: URL(fileURLWithPath: "/tmp/nonexistent-work"))
        let accB = CostAccount(id: "claude-personal", provider: "claude", name: "Personal",
                               configDirectory: URL(fileURLWithPath: "/tmp/nonexistent-personal"))
        CostAccountStore.testAccountsOverride = [accA, accB]

        // Enable master history, but ONLY authorize accA ("claude-work")
        prefs.isHistoryIndexingEnabled = true
        prefs.setConnected(true, for: "claude-work")
        prefs.setConnected(true, for: "claude-personal")
        prefs.setHistoryEnabled(true, for: "claude-work")
        prefs.setHistoryEnabled(false, for: "claude-personal")

        // Inject the single preferences instance into CostModels
        CostModels.configure(preferences: prefs, disconnected: [])

        XCTAssertTrue(CostModels.isHistoryEnabled(for: "claude-work"))
        XCTAssertFalse(CostModels.isHistoryEnabled(for: "claude-personal"))

        // Calls from card/timeline/settings cannot circumvent gates:
        XCTAssertNotNil(CostModels.model(for: "claude-work"), "Authorized account must return a model")
        XCTAssertNil(CostModels.model(for: "claude-personal"), "Unauthorized account MUST return nil")

        // Provider disconnection in UsageStore syncs and revokes authorization
        CostModels.synchronize(with: prefs, disconnected: ["claude-work"])
        XCTAssertFalse(CostModels.isHistoryEnabled(for: "claude-work"),
                       "Disconnected provider must not have history enabled")
        XCTAssertNil(CostModels.model(for: "claude-work"), "Disconnected provider model must be unloaded")

        // detectPlanIfDue must not run for unauthorized account
        CostAccountStore.shared.detectPlanIfDue("claude-personal")
        XCTAssertNil(CostAccountStore.shared.account("claude-personal")?.planTier)
    }

    // MARK: - 3. Disabling cancels/drains pending writes, reload tasks, and stops watchers

    func testDisablingCancelsAndDrainsPendingWritesAndReloadTasks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("agentcost-test.sqlite")
        let store = try XCTUnwrap(CostStore(url: dbURL))
        let account = CostAccount(id: "test-drain", provider: "claude", name: "Drain Test",
                                  configDirectory: tempDir)

        let model = CostModel(account: account, directory: tempDir, store: store)
        XCTAssertFalse(model.isStopped)

        // Launch detached tasks and reload
        let win = LimitWindow(id: "session", label: "Current session", usedFraction: 0.1,
                              resetsAt: Date().addingTimeInterval(3600))
        let snap = ProviderSnapshot(id: "test-drain", displayName: "Test", glyph: .claude,
                                    fidelity: .official, status: .ok, windows: [win])
        model.observe([snap])
        model.reload()

        // Stop the model: cancels pendingTasks and reloadTask, closes store
        model.stop()
        XCTAssertTrue(model.isStopped, "Model must be marked stopped")

        // Subsequent observe and reload calls must be clean no-ops without accessing closed store
        model.observe([snap])
        model.reload()
        XCTAssertTrue(model.isStopped)
    }

    // MARK: - 4. Retention: Automatic pruning & absent-vs-zero preference distinction

    func testRetentionAutomaticPruningAndRetentionDaysZeroVsAbsent() throws {
        let suiteName = "com.vinz.codenotch.retention.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!

        // Case A: Absent default initializes as 30
        let prefsAbsent = Preferences(defaults: testDefaults)
        XCTAssertEqual(prefsAbsent.historyRetentionDays, 30, "Absent retention key must default to 30")

        // Case B: Explicitly saved 0 ("Keep indefinitely") must initialize as 0
        testDefaults.set(0, forKey: "historyRetentionDays")
        let prefsZero = Preferences(defaults: testDefaults)
        XCTAssertEqual(prefsZero.historyRetentionDays, 0, "Explicitly saved 0 must not be overwritten with 30")

        // Case C: Explicitly saved 14
        testDefaults.set(14, forKey: "historyRetentionDays")
        let prefs14 = Preferences(defaults: testDefaults)
        XCTAssertEqual(prefs14.historyRetentionDays, 14)

        // Test automatic pruning of events and stale cursors
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("agentcost-ret.sqlite")
        let store = try XCTUnwrap(CostStore(url: dbURL))

        let now = Date()
        let oldTs = Int(now.addingTimeInterval(-20 * 86400).timeIntervalSince1970)
        let freshTs = Int(now.timeIntervalSince1970)

        // Commit an old event and a fresh event
        let oldEvent = UsageEvent(ts: oldTs, sessionId: "s-old", dedupeKey: "d-old", project: "p",
                                  cwd: "/tmp", branch: nil, model: "m", input: 10, output: 10,
                                  cacheRead: 0, cacheWrite: 0, ccVersion: nil)
        let freshEvent = UsageEvent(ts: freshTs, sessionId: "s-fresh", dedupeKey: "d-fresh", project: "p",
                                    cwd: "/tmp", branch: nil, model: "m", input: 20, output: 20,
                                    cacheRead: 0, cacheWrite: 0, ccVersion: nil)

        store.commit(events: [oldEvent], path: "/tmp/old.jsonl", inode: 1, size: 100, offset: 100,
                     mtime: Double(oldTs))
        store.commit(events: [freshEvent], path: "/tmp/fresh.jsonl", inode: 2, size: 200, offset: 200,
                     mtime: Double(freshTs))

        XCTAssertEqual(store.stats().events, 2)
        XCTAssertNotNil(store.fileCursor("/tmp/old.jsonl"))
        XCTAssertNotNil(store.fileCursor("/tmp/fresh.jsonl"))

        // Prune older than 14 days
        let cutoff = now.addingTimeInterval(-14 * 86400)
        let pruned = try store.prune(olderThan: cutoff)
        XCTAssertEqual(pruned, 1, "Only the 20-day old event should be pruned")
        XCTAssertEqual(store.stats().events, 1, "Only the fresh event should remain")

        // Verify stale file_cursor for old.jsonl was pruned (stale path metadata removed)
        XCTAssertNil(store.fileCursor("/tmp/old.jsonl"), "Stale file cursor must be pruned")
        XCTAssertNotNil(store.fileCursor("/tmp/fresh.jsonl"), "Active file cursor must be retained")

        // Verify durable retention cutoff in store_metadata prevents resurrection
        XCTAssertEqual(store.metadata("retention_cutoff_ts"), String(Int(cutoff.timeIntervalSince1970)))
    }

    // MARK: - 5. Clear ALL owned history DBs (including disabled/deleted accounts)

    func testClearAllHistoryCoversDisabledAndOrphanedDatabases() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-all-dbs-\(UUID().uuidString)", isDirectory: true)
        let costsDir = tempDir.appendingPathComponent("costs", isDirectory: true)
        try FileManager.default.createDirectory(at: costsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 3 databases:
        // 1. Enabled account
        // 2. Disabled account
        // 3. Orphaned / deleted account database remaining on disk
        let db1URL = costsDir.appendingPathComponent("agentcost-enabled.sqlite")
        let db2URL = costsDir.appendingPathComponent("agentcost-disabled.sqlite")
        let db3URL = costsDir.appendingPathComponent("agentcost-orphaned.sqlite")

        let store1 = try XCTUnwrap(CostStore(url: db1URL))
        let store2 = try XCTUnwrap(CostStore(url: db2URL))
        let store3 = try XCTUnwrap(CostStore(url: db3URL))

        let now = Int(Date().timeIntervalSince1970)
        let ev1 = UsageEvent(ts: now, sessionId: "s1", dedupeKey: "d1", project: "p1", cwd: "/tmp", branch: nil,
                             model: "m", input: 10, output: 10, cacheRead: 0, cacheWrite: 0, ccVersion: nil)
        let ev2 = UsageEvent(ts: now, sessionId: "s2", dedupeKey: "d2", project: "p2", cwd: "/tmp", branch: nil,
                             model: "m", input: 20, output: 20, cacheRead: 0, cacheWrite: 0, ccVersion: nil)
        let ev3 = UsageEvent(ts: now, sessionId: "s3", dedupeKey: "d3", project: "p3", cwd: "/tmp", branch: nil,
                             model: "m", input: 30, output: 30, cacheRead: 0, cacheWrite: 0, ccVersion: nil)

        store1.commit(events: [ev1], path: "/tmp/path1.jsonl", inode: 1, size: 50, offset: 50, mtime: Double(now))
        store2.commit(events: [ev2], path: "/tmp/path2.jsonl", inode: 2, size: 50, offset: 50, mtime: Double(now))
        store3.commit(events: [ev3], path: "/tmp/path3.jsonl", inode: 3, size: 50, offset: 50, mtime: Double(now))

        store1.quiesce()
        store2.quiesce()
        store3.quiesce()

        // Also add non-database files in costsDir to verify they are preserved
        let accountsJSON = costsDir.appendingPathComponent("accounts.json")
        let pricesJSON = costsDir.appendingPathComponent("prices.json")
        try "{\"test\":\"config\"}".write(to: accountsJSON, atomically: true, encoding: .utf8)
        try "{\"test\":\"prices\"}".write(to: pricesJSON, atomically: true, encoding: .utf8)

        // Run clearAllHistory pointing to this directory
        let clearResult = CostModels.clearAllHistory(costsDirectory: costsDir)

        XCTAssertTrue(clearResult.success, "Clear all history must report success")
        XCTAssertEqual(clearResult.clearedCount, 3, "All 3 databases must be cleared")
        XCTAssertTrue(clearResult.errors.isEmpty, "No errors should occur")

        // Verify configuration JSONs were PRESERVED
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountsJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pricesJSON.path))

        // Verify all 3 stores are now empty, file cursors purged, and history_cleared_at set
        for url in [db1URL, db2URL, db3URL] {
            let reopened = try XCTUnwrap(CostStore(url: url))
            XCTAssertEqual(reopened.stats().events, 0, "\(url.lastPathComponent) must have 0 events")
            XCTAssertEqual(reopened.stats().files, 0, "\(url.lastPathComponent) file cursors must be purged")
            XCTAssertNotNil(reopened.metadata("history_cleared_at"),
                            "\(url.lastPathComponent) must have anti-resurrection timestamp set")
            reopened.quiesce()
        }
    }

    // MARK: - 6. Restrictive 0700/0600 permissions & atomic file creation

    func testRestrictiveFilePermissionsAndWriteAtomically() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-perms-\(UUID().uuidString)", isDirectory: true)
        let codenotchDir = tempDir.appendingPathComponent("Codenotch", isDirectory: true)
        let costsDir = codenotchDir.appendingPathComponent("costs", isDirectory: true)

        try PrivacyFileProtection.secureDirectory(at: costsDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Both target directory and parent NotchAgent directory must be 0700
        XCTAssertEqual(PrivacyFileProtection.currentPermissions(at: costsDir), 0o700)
        XCTAssertEqual(PrivacyFileProtection.currentPermissions(at: codenotchDir), 0o700)

        // Test atomic write with 0600 creation permissions
        let testJSON = costsDir.appendingPathComponent("test-atomic.json")
        try PrivacyFileProtection.writeAtomically(data: Data("{\"hello\":\"world\"}".utf8), to: testJSON)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testJSON.path))
        XCTAssertEqual(PrivacyFileProtection.currentPermissions(at: testJSON), 0o600)

        // Test database file permissions
        let dbURL = costsDir.appendingPathComponent("costs.sqlite")
        let store = try XCTUnwrap(CostStore(url: dbURL))

        let event = UsageEvent(ts: Int(Date().timeIntervalSince1970), sessionId: "s1",
                               dedupeKey: "d1", project: "p1", cwd: "/tmp", branch: nil,
                               model: "m", input: 1, output: 1, cacheRead: 0, cacheWrite: 0,
                               ccVersion: nil)
        store.commit(events: [event], path: "/tmp/f1", inode: 1, size: 10, offset: 10, mtime: 1.0)

        XCTAssertEqual(PrivacyFileProtection.currentPermissions(at: dbURL), 0o600)

        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            XCTAssertEqual(PrivacyFileProtection.currentPermissions(at: walURL), 0o600)
        }
        store.quiesce()
    }

    // MARK: - 7. Complete erase helper: actor-safe, scoped accounts & preserves borrowed credentials

    func testEraseAllDataAwaitsQuiescenceAndScopesKeychainAccount() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("erase-fixture-\(UUID().uuidString)", isDirectory: true)
        let appSupport = tempDir.appendingPathComponent("Application Support", isDirectory: true)
        let codenotchDir = appSupport.appendingPathComponent("Codenotch", isDirectory: true)
        let library = tempDir.appendingPathComponent("Library", isDirectory: true)

        try FileManager.default.createDirectory(at: codenotchDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleID = "com.vinz.codenotch.eraseTest.\(UUID().uuidString)"
        let cachesDir = library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true)
        let webkitDir = library.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true)
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: webkitDir, withIntermediateDirectories: true)

        let testDefaults = UserDefaults(suiteName: bundleID)!
        testDefaults.set("pref-value", forKey: "testKey")

        var deletedKeychainQueries: [(service: String, account: String?)] = []
        let mockKeychainDeleter: (String, String?) throws -> Void = { service, account in
            deletedKeychainQueries.append((service: service, account: account))
        }

        var quiesceAwaited = false
        let mockQuiesce: () async throws -> Void = {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            quiesceAwaited = true
        }

        let result = await Preferences.eraseAllData(
            bundleID: bundleID,
            libraryDirectory: library,
            appSupportDirectory: appSupport,
            defaults: testDefaults,
            keychainDeleter: mockKeychainDeleter,
            quiesceWriters: mockQuiesce
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(quiesceAwaited, "Quiescence must be awaited BEFORE deletion")
        XCTAssertTrue(result.defaultsCleared)
        XCTAssertNil(testDefaults.string(forKey: "testKey"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codenotchDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: webkitDir.path))

        // Verify generic services deleted account="codenotch" specifically
        let ollamaQuery = deletedKeychainQueries.first { $0.service == "ollama-api-key" }
        XCTAssertNotNil(ollamaQuery)
        XCTAssertEqual(ollamaQuery?.account, "codenotch",
                       "Generic services must target account='codenotch' specifically")

        // Verify other app's credentials under the same service would NOT be matched
        let wouldDeleteOtherApp = deletedKeychainQueries.contains { $0.service == "ollama-api-key" && $0.account == "other-app" }
        XCTAssertFalse(wouldDeleteOtherApp, "Must NOT delete other app's accounts under generic services")

        // Verify borrowed credentials denylist: com.apify.cli, @apify/cli, Claude, Cursor, Gemini
        for borrowed in Preferences.borrowedKeychainServices {
            let deletedBorrowed = deletedKeychainQueries.contains { $0.service == borrowed }
            XCTAssertFalse(deletedBorrowed, "Borrowed credential '\(borrowed)' must NOT be deleted")
        }
        XCTAssertTrue(Preferences.borrowedKeychainServices.contains("com.apify.cli"))
        XCTAssertTrue(Preferences.borrowedKeychainServices.contains("@apify/cli"))
    }

    func testEraseHelperFailureReporting() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("erase-fail-\(UUID().uuidString)", isDirectory: true)
        let appSupport = tempDir.appendingPathComponent("Application Support", isDirectory: true)
        let library = tempDir.appendingPathComponent("Library", isDirectory: true)

        let testDefaults = UserDefaults(suiteName: "com.vinz.codenotch.fail.\(UUID().uuidString)")!

        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "Keychain item locked" }
        }

        let failingDeleter: (String, String?) throws -> Void = { service, _ in
            if service == "ollama-api-key" {
                throw TestError()
            }
        }

        let result = await Preferences.eraseAllData(
            bundleID: "com.vinz.codenotch.test",
            libraryDirectory: library,
            appSupportDirectory: appSupport,
            defaults: testDefaults,
            keychainDeleter: failingDeleter,
            quiesceWriters: {}
        )

        XCTAssertFalse(result.success)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(result.errors.contains { $0.contains("ollama-api-key") })
    }

    // MARK: - 8. CostIndexer deadlock-free stop & queue barrier

    func testCostIndexerQueueBarrierAndDeadlockFreeStop() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("indexer-deadlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        let store = try XCTUnwrap(CostStore(url: dbURL))
        var indexer: CostIndexer? = CostIndexer(store: store, root: tempDir, format: .claude)
        XCTAssertNotNil(indexer)

        // Verify calling stop() from external thread
        indexer?.stop()
        XCTAssertTrue(indexer?.isStopped == true)

        // Verify releasing indexer (deinit -> stop) does not deadlock even when final reference
        // drops in a background queue
        let exp = expectation(description: "deinit completed without deadlock")
        DispatchQueue.global().async {
            indexer = nil
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - 9. CostStore transaction rollback on execution failure

    func testCostStoreTransactionRollbackOnError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coststore-err-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("rollback.sqlite")
        let store = try XCTUnwrap(CostStore(url: dbURL))

        // Normal prune succeeds
        let deleted = try store.prune(olderThan: Date())
        XCTAssertEqual(deleted, 0)

        // Close store and verify CostStoreError.databaseClosed is thrown
        store.quiesce()
        XCTAssertThrowsError(try store.clearHistory()) { error in
            guard let storeErr = error as? CostStoreError else {
                XCTFail("Expected CostStoreError, got \(error)")
                return
            }
            XCTAssertEqual(storeErr, CostStoreError.databaseClosed)
        }
    }
}
