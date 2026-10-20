import Foundation

/// Reads the "Cloud usage" section of `https://ollama.com/settings`.
///
/// Since October 2026 the API reports request counts only; the session
/// (5-hour) and weekly percentages appear nowhere but this page, for a signed-in
/// browser. Each meter carries its figure in an accessibility label, followed by
/// the exact reset time:
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

        guard !windows.isEmpty else {
            // No meters and nothing to sign out of is a signed-out page; no
            // meters on a signed-in one means the page changed under us.
            if html.contains("/signout") { throw UsageProviderError.badResponse(status: 200) }
            throw UsageProviderError.needsAuth
        }
        return OllamaUsage.Result(windows: windows, headlineID: "session")
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
