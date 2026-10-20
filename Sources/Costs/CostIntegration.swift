import AppKit
import Combine
import SwiftUI

/// Where the cost layer plugs into the app: the cost models watch the usage
/// store's snapshots, a Claude card borrows the token chart the Codex card
/// has, and the Activity window opens from the menu.
@MainActor
enum Costs {
    private static var subscriptions: [AnyCancellable] = []
    private static var activityWindow: NSWindow?
    private static var retentionTimer: Timer?

    static func resumeForTesting() {
        precondition(Runtime.isUnderTest)
        isSuppressed = false
    }
    private(set) static var isSuppressed = false

    /// What a Claude login's card gains before the notch draws it: the daily
    /// token chart and summary the Codex server publishes for Codex, built
    /// here from the transcripts Claude Code writes.
    static func decorate(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        // The suite compares cells to what it fed in; the machine's own
        // accounts and transcripts must not leak into that.
        guard !Runtime.isUnderTest, !isSuppressed, snapshot.tokenUsage == nil,
              let usage = CostModels.model(for: snapshot.id)?.tokenUsage else { return snapshot }
        var snapshot = snapshot
        snapshot.tokenUsage = usage
        return snapshot
    }

    /// Stops all cost monitoring, cancels subscriptions, and suppresses background writes.
    static func detach() {
        retentionTimer?.invalidate()
        retentionTimer = nil
        subscriptions.removeAll()
        isSuppressed = true
        CostModels.stopAll()
    }

    static func attach(to store: UsageStore, preferences: Preferences? = nil) {
        let prefs = preferences ?? CostModels.preferences ?? Preferences()
        isSuppressed = false

        _ = PlanCatalog.shared
        _ = PriceTable.shared
        _ = CostAccountStore.shared

        subscriptions.removeAll()

        // Configure single preferences instance and disconnected set
        CostModels.configure(preferences: prefs, disconnected: store.disconnected)

        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { snapshots in
                guard !isSuppressed else { return }
                if !Runtime.isUnderTest {
                    CostAccountStore.shared.rediscover()
                }
                for snap in snapshots {
                    guard CostModels.isHistoryEnabled(for: snap.id),
                          let model = CostModels.model(for: snap.id) else { continue }
                    model.observe(snapshots)
                }
            }
            .store(in: &subscriptions)

        Publishers.CombineLatest4(
            store.$disconnected,
            prefs.$isHistoryIndexingEnabled,
            prefs.$enabledHistoryAccountIDs,
            prefs.$connectedProviders
        )
        .receive(on: RunLoop.main)
        .sink { disconnected, _, _, _ in
            guard !isSuppressed else { return }
            CostModels.synchronize(with: prefs, disconnected: disconnected)
        }
        .store(in: &subscriptions)

        retentionTimer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak prefs] _ in
            MainActor.assumeIsolated {
                guard !isSuppressed, let prefs, prefs.isHistoryIndexingEnabled else { return }
                CostModels.pruneAll(days: prefs.historyRetentionDays)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer

        // Automatic retention pruning when retention preference changes
        prefs.$historyRetentionDays
            .receive(on: RunLoop.main)
            .sink { days in
                guard !isSuppressed, prefs.isHistoryIndexingEnabled, days > 0 else { return }
                CostModels.pruneAll(days: days)
            }
            .store(in: &subscriptions)
    }

    static func showActivity() {
        if activityWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.t("Activity")
            w.minSize = NSSize(width: 900, height: 560)
            w.contentViewController = NSHostingController(rootView: TimelinePane().frame(minWidth: 900, minHeight: 560))
            w.isReleasedWhenClosed = false
            w.center()
            activityWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        activityWindow?.makeKeyAndOrderFront(nil)
    }
}
