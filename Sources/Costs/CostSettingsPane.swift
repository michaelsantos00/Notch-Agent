import SwiftUI

/// Settings › Costs: how each login is paid, the plan detected for it, and
/// the market data the money is worked out from.
struct CostSettingsPane: View {
    @ObservedObject var accounts: CostAccountStore = .shared
    @ObservedObject var prices: PriceTable = .shared
    @ObservedObject var catalog: PlanCatalog = .shared
    @ObservedObject var preferences: Preferences

    init(preferences: Preferences? = nil) {
        self.preferences = preferences ?? CostModels.preferences ?? Preferences()
    }

    var body: some View {
        Form {
            if accounts.accounts.isEmpty {
                Section(L10n.t("Billing")) {
                    Text(L10n.t("Connect a Claude or Codex account to configure its billing."))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(accounts.accounts) { account in
                Section(account.name) {
                    CostAccountRows(account: account)
                }
            }

            Section(L10n.t("Cost estimates")) {
                Button(L10n.t("Open Activity…")) { Costs.showActivity() }
                Text(L10n.t("View daily, weekly, and monthly estimates by account and project. Enable local history tracking in Privacy to include transcript usage."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L10n.t("How estimates work")) {
                    Text(L10n.t("Subscription cost is allocated by each project's share of the weekly allowance. Weekly cost is the monthly price divided by 4.35. API usage uses local per-token prices. These estimates may differ from your provider's bill."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.t("Local pricing")) {
                LabeledContent(L10n.t("Exchange rate")) {
                    if prices.currency == "USD" {
                        Text("1 USD = 1.00 USD")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Text("1 USD =")
                            TextField("", value: $prices.rate, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text(prices.currency)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent(L10n.t("Per-token prices")) {
                    HStack(spacing: 8) {
                        Text(L10n.t("\(prices.prices.count) bundled/local models")).foregroundStyle(.secondary)
                        Button(L10n.t("Show prices file")) { NSWorkspace.shared.activateFileViewerSelecting([PriceTable.fileURL]) }
                    }
                }
                LabeledContent(L10n.t("Plan catalog")) {
                    HStack(spacing: 8) {
                        Text(L10n.t("\(catalog.plans.count) local plans")).foregroundStyle(.secondary)
                        Button(L10n.t("Show plans file")) { NSWorkspace.shared.activateFileViewerSelecting([PlanCatalog.fileURL]) }
                    }
                }
                Button(L10n.t("Reload local files")) { prices.refreshIfDue(force: true); catalog.refreshIfDue(force: true) }
                Text(L10n.t("Prices and plans are bundled with the app. Edit local files or the exchange rate here; reloading never downloads data."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }


        }
        .formStyle(.grouped)
    }
}

/// One login's billing: how it is paid, what it costs, and the plan detected.
private struct CostAccountRows: View {
    let account: CostAccount
    @ObservedObject private var accounts = CostAccountStore.shared
    @ObservedObject private var prices = PriceTable.shared
    @ObservedObject private var catalog = PlanCatalog.shared

    var body: some View {
        let auto = account.monthlyLocal(rate: prices.rate)
        Picker(L10n.t("Billing"), selection: Binding(get: { account.billing }, set: { accounts.setBilling(account.id, $0) })) {
            ForEach(CostAccount.Billing.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)

        if account.billing == .subscription {
            LabeledContent(L10n.t("Monthly cost")) {
                TextField("", value: Binding(get: { account.monthlyPrice == 0 ? nil : account.monthlyPrice },
                                             set: { accounts.setMonthlyPrice(account.id, $0 ?? 0) }),
                          format: .number,
                          prompt: Text(auto > 0 ? MoneyFormat.string(auto, currency: prices.currency) : "—"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
            LabeledContent(L10n.t("Plan")) {
                Text(planDetail).foregroundStyle(.secondary)
            }
        }
    }

    private var planDetail: String {
        guard let tier = account.planTier else { return L10n.t("Plan not detected yet") }
        let name = catalog.name(for: tier)
        if let local = catalog.monthly(for: tier, currency: prices.currency, rate: prices.rate) {
            return L10n.t("\(name) · \(MoneyFormat.string(local, currency: prices.currency))/month (local catalog)")
        }
        return L10n.t("\(name) · enter a monthly cost above")
    }
}
