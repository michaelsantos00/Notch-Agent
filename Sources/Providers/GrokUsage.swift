import CoreFoundation
import Foundation

/// Parses Grok CLI's billing endpoints, recorded from a live SuperGrok session:
///
/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
/// ```json
/// { "config": {
///     "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
///                        "start": "2026-09-05T08:21:18.802818+00:00",
///                        "end":   "2026-09-12T08:21:18.802818+00:00" },
///     "creditUsagePercent": 8.0,
///     "productUsage": [{ "product": "GrokBuild", "usagePercent": 8.0 }],
///     "billingPeriodStart": "2026-09-05T08:21:18.802818+00:00",
///     "billingPeriodEnd":   "2026-09-12T08:21:18.802818+00:00" } }
/// ```
///
/// `creditUsagePercent` measures the shared subscription pool. Product rows
/// describe how that pool was used.
enum GrokUsage {
    static func reading(creditsJSON: String) throws -> (window: LimitWindow, isWeekly: Bool) {
        guard let credits = object(creditsJSON)?["config"] as? [String: Any] else {
            throw UsageProviderError.badResponse(status: 0)
        }

        let currentPeriod = period(credits["currentPeriod"])
        let currentEnd = date(currentPeriod?["end"])
        let creditsReset = currentEnd ?? date(credits["billingPeriodEnd"])
        let start = currentEnd == nil
            ? date(credits["billingPeriodStart"]) : date(currentPeriod?["start"])
        let duration = creditsReset.flatMap { end in
            start.flatMap { $0 < end ? end.timeIntervalSince($0) : nil }
        }

        guard let fraction = percent(credits["creditUsagePercent"]) else {
            if creditsReset != nil || credits["productUsage"] != nil || credits["prepaidBalance"] != nil {
                throw UsageProviderError.apiError(L10n.t("Grok did not report its shared usage percentage."))
            }
            throw UsageProviderError.nothingMetered(L10n.t("Grok has nothing metered on this account yet"))
        }
        let type = currentPeriod?["type"] as? String
        let label: String
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": label = L10n.t("Weekly limit")
        case "USAGE_PERIOD_TYPE_MONTHLY": label = L10n.t("Monthly limit")
        default: label = L10n.t("Credits")
        }
        let window = LimitWindow(id: "credits", label: label, usedFraction: fraction,
                                 resetsAt: creditsReset, duration: duration)
        return (window, type == "USAGE_PERIOD_TYPE_WEEKLY")
    }

    private static func percent(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue / 100
    }

    private static func period(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func date(_ any: Any?) -> Date? {
        GrokCredentials.date(any)
    }
}
