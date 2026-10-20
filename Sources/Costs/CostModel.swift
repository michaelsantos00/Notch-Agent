import Foundation
import SwiftUI
import Combine

/// Drives the "what used it" section of the Claude card.
///
/// The limit itself only tells you how much is gone. This pairs each observed
/// increase with the local turns that happened in the same interval, so the card
/// can say *which project* spent it. Everything is computed locally from files
/// Claude Code already wrote; no extra requests, no accounts.
@MainActor
final class CostModel: ObservableObject {

    let account: CostAccount

    enum State {
        case unavailable      // no transcripts on this machine — hide the section
        case waiting          // indexed, but no measurable consumption yet
        case ready
    }

    @Published private(set) var rows: [ProjectCost] = []
    /// Tokens per day and the summary the card's chart reads, from the
    /// transcripts; Codex brings its own from the server.
    @Published private(set) var tokenUsage: CodexTokenUsage?
    @Published private(set) var state: State = .unavailable
    /// False for plans with no rolling limits (credit-based seats): the session
    /// and week views need limit samples, so only month and all-time apply.
    @Published private(set) var quotaBacked = true
    /// The allowance the "week" tab measures: the weekly limit, or the credit
    /// cycle for credit-based seats.
    @Published private(set) var allowance: CostWindow = .weekly
    var creditBacked: Bool { allowance == .credits }

    @Published var isExpanded: Bool {
        didSet { PersistentWrites.perform { defaults.set(isExpanded, forKey: Self.expandedKey) } }
    }

    /// Which range the list is showing. Persisted, like the expanded state.
    @Published var range: CostRange {
        didSet {
            PersistentWrites.perform { defaults.set(range.rawValue, forKey: Self.rangeKey) }
            reload()
        }
    }

    private static let expandedKey = "costExpanded"
    private static let rangeKey = "costRange"
    private let defaults: UserDefaults
    private let store: CostStore?
    private let indexer: CostIndexer?
    private(set) var isStopped = false
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?

    init(account: CostAccount, directory: URL? = nil, store: CostStore? = nil, defaults: UserDefaults? = nil) {
        self.account = account
        let defaults = defaults ?? (Runtime.isUnderTest ? UserDefaults(suiteName: "codenotch.cost-model-test.\(UUID().uuidString)")! : .standard)
        self.defaults = defaults
        isExpanded = defaults.bool(forKey: Self.expandedKey)
        let saved = CostRange(rawValue: defaults.string(forKey: Self.rangeKey) ?? "") ?? .session
        range = saved == .allTime ? .month : saved

        if let store {
            self.store = store
        } else {
            let dir: URL
            if let directory {
                dir = directory
            } else if Runtime.isUnderTest {
                dir = FileManager.default.temporaryDirectory.appendingPathComponent("codenotch-costs-test-\(account.id)-\(UUID().uuidString)")
            } else {
                dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Codenotch/costs", isDirectory: true)
            }
            let dbName = "agentcost-\(account.id).sqlite"
            self.store = CostStore(url: dir.appendingPathComponent(dbName))
        }

        indexer = self.store.flatMap {
            CostIndexer(store: $0, root: account.transcriptsRoot, format: account.provider == "codex" ? .codex : .claude)
        }

        // Automatically prune retention on model initialization if retention is configured
        if let retDays = CostModels.preferences?.historyRetentionDays, retDays > 0 {
            try? self.store?.prune(olderThan: Calendar.current.date(byAdding: .day, value: -retDays, to: Date()) ?? Date.distantPast)
        }

        guard let indexer else { return }
        state = .waiting
        indexer.onChange = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        indexer.start()
        reload()
    }

    /// Quiesces the model, stops its indexer watcher, cancels pending tasks, and quiesces the store.
    func stop() {
        isStopped = true
        reloadTask?.cancel()
        reloadTask = nil
        indexer?.stop()
        for t in pendingTasks.values { t.cancel() }
        pendingTasks.removeAll()
        store?.quiesce()
    }

    func pruneRetention(days: Int) throws {
        guard let store, !isStopped, days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        try store.prune(olderThan: cutoff)
        reload()
    }

    func clearHistory() {
        guard let store, !isStopped else { return }
        try? store.clearHistory(preserveFileCursors: false)
        reload()
    }

    /// Called after every usage poll. Samples the limit and attributes any increase.
    /// NotchAgent's windows carry ids: "session"/"primary" are the rolling
    /// session, "weekly_all"/"secondary" the week, anything named credits the
    /// credit cap of a Business seat.
    func observe(_ snapshots: [ProviderSnapshot]) {
        guard !isStopped, let store, let snap = snapshots.first(where: { $0.id == account.id }) else { return }
        let samples: [(window: CostWindow, pct: Double, resetsAt: Date?)] = snap.windows.compactMap { w in
            guard let f = w.usedFraction else { return nil }
            let window: CostWindow
            switch w.id {
            case "session", "primary": window = .session
            case "weekly_all", "weekly", "secondary": window = .weekly
            default:
                if w.id.lowercased().contains("credit") || w.label.lowercased().contains("credit") { window = .credits } else { return nil }
            }
            if window == .credits, let used = w.used, let remaining = w.remaining {
                CostAccountStore.shared.setCreditLimit(account.id, Double(used + remaining))
            }
            return (window, f * 100, w.resetsAt)
        }
        if samples.isEmpty {
            if quotaBacked { quotaBacked = false; if range.window != nil { range = .month } }
            return
        }
        if !quotaBacked { quotaBacked = true }
        let win: CostWindow = samples.contains { $0.window == .credits } ? .credits : .weekly
        if allowance != win { allowance = win; if range == .session && win == .credits { range = .weekly } }
        CostAccountStore.shared.detectPlanIfDue(account.id)

        let taskID = UUID()
        let task = Task.detached(priority: .utility) { [weak self, weak store] in
            defer {
                Task { @MainActor [weak self] in
                    self?.pendingTasks.removeValue(forKey: taskID)
                }
            }
            guard let store, !Task.isCancelled else { return }
            for s in samples {
                if Task.isCancelled { break }
                store.recordSample(window: s.window, pct: s.pct, resetsAt: s.resetsAt)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                self.reload()
            }
        }
        pendingTasks[taskID] = task
    }

    func reload() {
        guard !isStopped, let store else { return }
        reloadTask?.cancel()
        let range = (quotaBacked || self.range.window == nil) ? self.range : .month
        let pricer = PriceTable.shared.pricer
        let account = self.account
        let monthlyLocal = account.monthlyLocal(rate: pricer.rate)
        let quotaBacked = self.quotaBacked
        let allowance = self.allowance
        let creditPoint: Double? = (allowance == .credits && account.creditLimit != nil)
            ? account.creditLocal(rate: pricer.rate).map { $0 * account.creditLimit! / 100 } : nil

        reloadTask = Task.detached(priority: .utility) { [weak self, weak store] in
            guard !Task.isCancelled, let store else { return }
            // The "week" tab reads the account's allowance window (weekly limit or credit cycle).
            var fresh: [ProjectCost]
            if range == .weekly { fresh = store.currentPeriod(window: allowance) } else { fresh = store.rows(for: range) }
            guard !Task.isCancelled else { return }

            // Money for the same interval, from the tokens of each project.
            let now = Int(Date().timeIntervalSince1970)
            let from: Int
            if range == .weekly { from = store.currentPeriodStart(window: allowance) }
            else if let w = range.window { from = store.currentPeriodStart(window: w) }
            else if let d = range.start { from = Int(d.timeIntervalSince1970) }
            else { from = 0 }
            guard !Task.isCancelled else { return }

            let costs: [String: Double]
            switch account.billing {
            case .api:
                costs = store.projectCosts(from: from, to: now, pricer: pricer)
            case .subscription where quotaBacked && creditPoint != nil:
                // Credit-based seat: 1 % of the cycle's allowance = limit ÷ 100 credits.
                let pct = store.attributedPct(window: .credits, from: from, to: now)
                costs = pct.mapValues { creditPoint! * $0 }
            case .subscription where quotaBacked:
                // A week of the plan costs price ÷ 4.35; a project that consumed
                // 4 % of the weekly allowance spent 4 % of that.
                let weekly = monthlyLocal / CostEstimator.weeksPerMonth
                let pct = store.attributedWeeklyPct(from: from, to: now)
                costs = weekly > 0 ? pct.mapValues { weekly * $0 / 100 } : [:]
            case .subscription:
                // No rolling limit to anchor on: the plan is spread over the
                // month's tokens.
                let month = store.totalWeight(from: CostEstimator.monthStart(), to: now)
                let (byProject, _) = store.weightsPublic(from: from - 1, to: now)
                costs = (monthlyLocal > 0 && month > 0) ? byProject.mapValues { monthlyLocal * $0 / month } : [:]
            }
            guard !Task.isCancelled else { return }

            // Inside the allowance window every row's share is already the
            // share of that window, so its money is that share of the plan:
            // the same number for every row, whether its share came from a
            // recorded jump or from the gap spread over the tokens.
            let perPoint: Double?
            switch account.billing {
            case .subscription where quotaBacked && creditPoint != nil && range == .weekly:
                perPoint = creditPoint
            case .subscription where quotaBacked && range == .weekly:
                let weekly = monthlyLocal / CostEstimator.weeksPerMonth
                perPoint = weekly > 0 ? weekly / 100 : nil
            default:
                perPoint = nil
            }
            for i in fresh.indices where !fresh[i].isUnexplained {
                fresh[i].cost = perPoint.map { $0 * fresh[i].pct } ?? costs[fresh[i].project]
            }
            let done = fresh.presentable()
            let usage = store.tokenUsage()
            await MainActor.run {
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                self.rows = done
                self.state = done.isEmpty ? .waiting : .ready
                if self.tokenUsage != usage { self.tokenUsage = usage }
            }
        }
    }

    var store_: CostStore? { store }

    /// Diagnostics line for the settings menu.
    func statsLine() -> String? {
        guard let store else { return nil }
        let st = store.stats()
        guard st.events > 0 || st.files > 0 else { return nil }
        if st.errors > 0 { return L10n.t("\(st.events) turns · \(st.files) files · \(st.errors) skipped") }
        return L10n.t("\(st.events) turns · \(st.files) files")
    }
}


/// One CostModel per account (Claude and Codex), created lazily and kept while the account exists.
@MainActor
enum CostModels {
    private static var byAccount: [String: CostModel] = [:]
    /// Fires whenever any model's rows or expansion change (panel re-measures).
    static let anyChange = PassthroughSubject<Void, Never>()
    private static var subs: [String: [AnyCancellable]] = [:]

    /// The single shared Preferences instance, injected from root or tests.
    static var preferences: Preferences?
    static var disconnected: Set<String> = []

    /// Configures the single preferences instance and disconnected set.
    static func configure(preferences: Preferences, disconnected: Set<String> = []) {
        self.preferences = preferences
        self.disconnected = disconnected
        synchronize(with: preferences, disconnected: disconnected)
    }

    /// Verifies whether history indexing is permitted for an account ID.
    /// Default is OFF for this private fork, limited to explicitly enabled accounts
    /// whose provider is also connected and not disconnected in UsageStore.
    static func isHistoryEnabled(for accountID: String) -> Bool {
        guard !Costs.isSuppressed, !PersistentWrites.isSuspended, let prefs = preferences else { return false }
        guard prefs.isHistoryIndexingEnabled else { return false }
        guard prefs.enabledHistoryAccountIDs.contains(accountID) else { return false }
        guard !disconnected.contains(accountID) && prefs.isConnected(accountID) else { return false }
        return true
    }

    static var all: [CostModel] {
        CostAccountStore.shared.accounts.compactMap { model(for: $0.id) }
    }

    /// Accesses the CostModel for an account ID.
    /// Strict gating: if history is disabled for this account, stops any active watcher/model
    /// and returns nil so callers (card, timeline, settings) cannot circumvent the gate.
    static func model(for accountID: String) -> CostModel? {
        guard isHistoryEnabled(for: accountID) else {
            disable(accountID)
            return nil
        }
        if let m = byAccount[accountID] { return m }
        guard let a = CostAccountStore.shared.account(accountID) else { return nil }
        let m = CostModel(account: a)
        byAccount[accountID] = m
        subs[accountID] = [
            m.$rows.dropFirst().sink { _ in anyChange.send() },
            m.$isExpanded.dropFirst().sink { _ in anyChange.send() },
        ]
        return m
    }

    /// Disables and stops the model for an account, releasing resources.
    static func disable(_ accountID: String) {
        if let m = byAccount.removeValue(forKey: accountID) {
            m.stop()
            subs.removeValue(forKey: accountID)
            anyChange.send()
        }
    }

    /// Stops all running models, watchers, and writers.
    static func stopAll() {
        for (_, m) in byAccount {
            m.stop()
        }
        byAccount.removeAll()
        subs.removeAll()
        anyChange.send()
    }

    /// Synchronizes active models against preferences and disconnected providers.
    static func synchronize(with preferences: Preferences? = nil, disconnected: Set<String>? = nil) {
        if let preferences { self.preferences = preferences }
        if let disconnected { self.disconnected = disconnected }
        for (accountID, model) in byAccount {
            if !isHistoryEnabled(for: accountID) {
                model.stop()
                byAccount.removeValue(forKey: accountID)
                subs.removeValue(forKey: accountID)
            }
        }
        anyChange.send()
    }

    /// Prunes retention across all active models and their stores.
    @discardableResult
    static func pruneAll(days: Int, costsDirectory: URL? = nil) -> [String] {
        guard days > 0, !PersistentWrites.isSuspended else { return [] }
        var errors: [String] = []
        for model in byAccount.values {
            do { try model.pruneRetention(days: days) }
            catch { errors.append("Retention failed for \(model.account.id).") }
        }
        // Also prune existing databases for accounts that are now disabled or removed.
        // Tests only touch their injected directory and active fixture models.
        guard !Runtime.isUnderTest || costsDirectory != nil else { return errors }
        let directory = costsDirectory ?? historyDirectory
        do {
            let activeNames = Set(byAccount.keys.map { "agentcost-\($0).sqlite" })
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
            for url in try ownedDatabases(in: directory) where !activeNames.contains(url.lastPathComponent) {
                guard let store = CostStore(url: url) else {
                    errors.append("Could not open \(url.lastPathComponent).")
                    continue
                }
                defer { store.quiesce() }
                do { try store.prune(olderThan: cutoff) }
                catch { errors.append("Retention failed for \(url.lastPathComponent).") }
            }
        } catch { errors.append("Could not read the history directory.") }
        return errors
    }

    private static var historyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Codenotch/costs", isDirectory: true)
    }

    private static func ownedDatabases(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { url in
                let name = url.lastPathComponent
                guard name == "agentcost.sqlite" || (name.hasPrefix("agentcost-") && name.hasSuffix(".sqlite")),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
    }

    /// Clears history across ALL owned history databases (including disabled or deleted accounts)
    /// found in the costs directory, ensuring no writer race and durable cutoff preventing backfill.
    ///
    /// Preserves configurations (accounts.json, prices.json, plans.json) and API keys.
    /// Clears path and session metadata (file_cursor) as well.
    @discardableResult
    static func clearAllHistory(costsDirectory: URL? = nil) -> (success: Bool, clearedCount: Int, errors: [String]) {
        // 1. Quiesce all active writers first to eliminate writer races
        stopAll()

        let dir: URL
        if let costsDirectory {
            dir = costsDirectory
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Codenotch/costs", isDirectory: true)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            return (true, 0, [])
        }

        guard let dbURLs = try? ownedDatabases(in: dir) else {
            return (false, 0, ["Could not read costs directory at \(dir.path)"])
        }

        var clearedCount = 0
        var errors: [String] = []

        for dbURL in dbURLs {
            guard let store = CostStore(url: dbURL) else {
                errors.append("Failed to open store at \(dbURL.lastPathComponent)")
                continue
            }
            do {
                try store.clearHistory(preserveFileCursors: false)
                store.quiesce()
                clearedCount += 1
            } catch {
                store.quiesce()
                errors.append("\(dbURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return (errors.isEmpty, clearedCount, errors)
    }
}
