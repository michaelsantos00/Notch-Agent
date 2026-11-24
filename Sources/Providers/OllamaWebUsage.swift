import Foundation

/// Reads included usage and credits from `https://ollama.com/settings`.
///
/// Legacy session and weekly meters carry their figures in accessibility
/// labels, followed by the exact reset time:
///
/// ```html
/// <div data-usage-track aria-label="Session usage 1.3% used">
///   <button data-usage-segment data-model="web search" data-requests="12">
/// </div>
/// <div class="local-time" data-time="2026-10-20T16:00:00Z"> Resets in 30 minutes.
/// ```
///
/// Those anchors are what screen readers and the page's own script rely on, so
/// they are the parts least likely to move when the styling does.
enum OllamaWebUsage {
    static let sessionCookie = "__Secure-session"
    static let sessionCookieNames = ["wos-session", sessionCookie]
    static let host = "ollama.com"
    static let page = URL(string: "https://ollama.com/settings")!

    static func parse(_ html: String) throws -> OllamaUsage.Result {
        var windows: [LimitWindow] = []
        for meter in [Meter(id: "session", title: "Session", label: L10n.t("Session usage"), duration: 5 * 3600),
                      Meter(id: "weekly", title: "Weekly", label: L10n.t("Weekly usage"), duration: 7 * 86400)] {
            guard let match = html.range(of: #"aria-label="\#(meter.title) usage ([0-9.]+)% used""#,
                                          options: .regularExpression),
                  let percent = Double(html[match].split(separator: " ")
                      .first { $0.hasSuffix("%") }?.dropLast() ?? "")
            else { continue }
            let after = html[match.upperBound...]
            let nextTime = after.range(of: #"data-time="[^"]+""#, options: .regularExpression)
            let resetsAt = nextTime.flatMap { range -> Date? in
                let quoted = after[range].dropFirst("data-time=\"".count).dropLast()
                return AntigravityCredentials.parse(String(quoted))
            }
            windows.append(LimitWindow(id: meter.id, label: meter.label, usedFraction: percent / 100,
                                       resetsAt: resetsAt, duration: meter.duration))
            if meter.id == "weekly" {
                let segments = after[..<(nextTime?.lowerBound ?? after.endIndex)]
                windows.append(contentsOf: models(in: String(segments)))
            }
        }

        if windows.isEmpty, let monthly = monthly(in: html) { windows.append(monthly) }
        windows.append(contentsOf: wallet(in: html))
        guard let first = windows.first else {
            // No meters and nothing to sign out of is a signed-out page; no
            // meters on a signed-in one means the page changed under us.
            if html.contains("/signout") { throw UsageProviderError.badResponse(status: 200) }
            throw UsageProviderError.needsAuth
        }
        return OllamaUsage.Result(windows: windows, headlineID: first.id)
    }

    static func sessions(home: URL) -> [BrowserCookies.Session] {
        let now = Date()
        var seen: Set<String> = []
        return sessionCookieNames.flatMap { BrowserCookies.sessions(named: $0, host: host, home: home) }
            .filter { ($0.expires ?? .distantFuture) > now && seen.insert($0.store.id).inserted }
    }

    private static func monthly(in html: String) -> LimitWindow? {
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        let meter = html.range(of: #">\s*(Monthly usage|Free usage)\s*<"#, options: options)
        guard let heading = meter ?? html.range(of: #">\s*Included usage\s*<"#, options: options) else { return nil }
        let tail = String(html[heading.upperBound...].prefix(4_000))
        let boundary = tail.range(of: #"</section\s*>|<h[1-6]\b|>\s*(Session|Hourly|Weekly) usage\s*<"#,
                                  options: options)
        let block = String(tail[..<(boundary?.lowerBound ?? tail.endIndex)])
        let periodEnd = captures(#"data-time="([^"]+)""#, in: block).first.flatMap(AntigravityCredentials.parse)
        let text = block.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let amounts = captures(#"\$([\d,.]+)\s+of\s+\$([\d,.]+)\s+used\b"#, in: text)
        if amounts.count == 2, let used = OllamaUsage.amount(amounts[0]),
           let allowance = OllamaUsage.amount(amounts[1]), allowance > 0 {
            return OllamaUsage.monthly(used: used, allowance: allowance, end: periodEnd)
        }
        let textPercent = captures(#"([0-9.]+)\s*%\s*used\b"#, in: text).first
        let meterWidth = meter.flatMap { _ in captures(#"\bwidth:\s*([0-9.]+)%"#, in: block).first }
        if let percent = OllamaUsage.amount(textPercent ?? meterWidth), percent <= 100 {
            return LimitWindow(id: "monthly", label: L10n.t("Monthly usage"), usedFraction: percent / 100,
                               resetsAt: periodEnd)
        }
        return nil
    }

    private static func wallet(in html: String) -> [LimitWindow] {
        let page = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#,
                                             with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let heading = #"<h[1-6][^>]*>\s*Usage credits(?:\s*<span[^>]*>[^<]*</span\s*>)?\s*</h[1-6]\s*>"#
        guard let block = captures(heading + #"(.*?)(?=</section\s*>|<h[1-6]\b|$)"#, in: page).first else { return [] }
        var rows: [LimitWindow] = []
        if let balance = captures(#"^\s*(?:<div[^>]*>\s*)*<span[^>]*>\s*\$([\d,.]+)\s*</span\s*>"#, in: block)
            .first.flatMap({ OllamaUsage.amount($0) }) {
            rows.append(OllamaUsage.creditBalance(balance))
        }
        if let used = captures(#">\s*Monthly credits used\s*</span\s*>\s*<span[^>]*>\s*\$([\d,.]+)\s*</span\s*>"#, in: block)
            .first.flatMap({ OllamaUsage.amount($0) }) {
            rows.append(LimitWindow(id: "monthly-spend", label: L10n.t("Monthly credits used"), usedText: OllamaUsage.usd(used)))
        }
        if !rows.isEmpty, let refill = captures(#"<p[^>]*>\s*(Refills\s+to\s+\$[\d,.]+\s+in\s+[^<]{1,160}?)\s*</p\s*>"#, in: block).first {
            rows.append(LimitWindow(id: "next-refill", label: L10n.t("Next refill"), usedText: refill))
        }
        return rows
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private struct Meter {
        let id: String
        let title: String
        let label: String
        let duration: TimeInterval
    }

    /// The weekly meter's segments: one per model, each with its requests.
    private static func models(in segments: String) -> [LimitWindow] {
        let pattern = #"data-model="([^"]*)" data-requests="([0-9]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(segments.startIndex..., in: segments)
        return regex.matches(in: segments, range: range).compactMap { match in
            guard let name = Range(match.range(at: 1), in: segments).map({ String(segments[$0]) }),
                  let count = Range(match.range(at: 2), in: segments).flatMap({ Int(segments[$0]) }),
                  !name.isEmpty
            else { return nil }
            return LimitWindow(id: "weekly.\(name)", label: name, used: count)
        }
    }
}
