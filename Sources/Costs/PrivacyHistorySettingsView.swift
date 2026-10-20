import SwiftUI

/// Privacy settings use the root application's coordinated erase operation.
struct PrivacyHistorySettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject private var accountStore = CostAccountStore.shared

    @State private var showingClearConfirmation = false
    @State private var showingEraseConfirmation = false
    @State private var statusMessage: String?
    @State private var isErasing = false

    init(preferences: Preferences? = nil) {
        self.preferences = preferences ?? CostModels.preferences ?? Preferences()
    }

    var body: some View {
        Form {
            Section(L10n.t("Network access")) {
                Text(L10n.t("Usage requests go directly to enabled providers or your configured endpoints. Local runtimes use their configured local connection."))
                Text(L10n.t("No analytics, automatic update checks, or background pricing downloads. Opening a website uses your browser and that site's privacy policy."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("Local history")) {
                SettingsToggleRow(title: L10n.t("Track local history"),
                                  detail: L10n.t("Off by default. Read local Claude and Codex transcripts to estimate project costs. Only usage metadata and token counts are saved; prompt and response text is never saved or uploaded."),
                                  isOn: $preferences.isHistoryIndexingEnabled)

                if preferences.isHistoryIndexingEnabled {
                    if accountStore.accounts.isEmpty {
                        Text(L10n.t("Connect a Claude or Codex account to track its history."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(accountStore.accounts) { account in
                            Toggle(isOn: Binding(
                                get: { preferences.enabledHistoryAccountIDs.contains(account.id) },
                                set: { preferences.setHistoryEnabled($0, for: account.id) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    if !preferences.isConnected(account.id) {
                                        Text(L10n.t("Paused while this provider is disabled in Accounts."))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Section(L10n.t("History retention")) {
                Picker(L10n.t("Keep history for"), selection: $preferences.historyRetentionDays) {
                    Text(L10n.t("7 days")).tag(7)
                    Text(L10n.t("30 days")).tag(30)
                    Text(L10n.t("90 days")).tag(90)
                    Text(L10n.t("180 days")).tag(180)
                    Text(L10n.t("1 year")).tag(365)
                    Text(L10n.t("Forever")).tag(0)
                }
                .pickerStyle(.menu)
                Text(preferences.isHistoryIndexingEnabled
                     ? L10n.t("Older records are removed automatically while history tracking is on. Removed records will not be imported again.")
                     : L10n.t("Automatic cleanup is paused while history tracking is off. You can still remove older records now."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if preferences.historyRetentionDays > 0 {
                    Button(L10n.t("Remove older records now")) { pruneRetention() }
                }
            }

            Section(L10n.t("Stored data")) {
                Text(L10n.t("History stays on this Mac. App data files are restricted to your macOS user account but are not encrypted by NotchAgent."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    Button(L10n.t("Clear local history…")) { showingClearConfirmation = true }
                        .confirmationDialog(L10n.t("Clear local history?"),
                                            isPresented: $showingClearConfirmation,
                                            titleVisibility: .visible) {
                            Button(L10n.t("Clear history"), role: .destructive) { clearHistory() }
                            Button(L10n.t("Cancel"), role: .cancel) {}
                        } message: {
                            Text(L10n.t("Permanently delete indexed history for all accounts, including disabled accounts. Accounts, settings, API keys, and original provider transcripts are kept. Deleted records will not be imported again."))
                        }
                    Text(L10n.t("Remove indexed history for all accounts. Keep settings and saved API keys."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Button(L10n.t("Erase all app data…")) { showingEraseConfirmation = true }
                        .disabled(AppDataErasure.shutdown == nil || isErasing)
                        .confirmationDialog(L10n.t("Erase all app data?"),
                                            isPresented: $showingEraseConfirmation,
                                            titleVisibility: .visible) {
                            Button(L10n.t("Erase and quit"), role: .destructive) {
                                isErasing = true
                                statusMessage = L10n.t("Stopping background work and erasing app data…")
                                Task {
                                    let result = await AppDataErasure.erase()
                                    if result.success {
                                        NSApp.terminate(nil)
                                    } else {
                                        statusMessage = L10n.t("Erasure could not finish. Background work is paused. Restart the app to try again.")
                                    }
                                }
                            }
                            Button(L10n.t("Cancel"), role: .cancel) {}
                        } message: {
                            Text(L10n.t("Permanently delete NotchAgent's history, settings, caches, and saved API keys, then quit. Provider-app logins and original transcripts are kept."))
                        }
                    Text(L10n.t("Reset NotchAgent and quit. Provider-app logins and original transcripts are kept."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(statusMessage)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isErasing)
    }

    private func pruneRetention() {
        let days = preferences.historyRetentionDays
        guard days > 0 else { return }
        let errors = CostModels.pruneAll(days: days)
        statusMessage = errors.isEmpty
            ? L10n.t("Removed history older than \(days) days.")
            : L10n.t("Some history could not be removed. Check file permissions and try again.")
    }

    private func clearHistory() {
        let result = CostModels.clearAllHistory()
        statusMessage = result.success
            ? L10n.t("Local history cleared. Deleted records will not be imported again.")
            : L10n.t("Some history could not be cleared. Check file permissions and try again.")
    }
}
