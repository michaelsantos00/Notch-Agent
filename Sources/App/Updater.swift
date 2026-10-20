import Foundation

/// In this privacy-hardened fork, automatic and manual network-based updates
/// are disabled to protect fork integrity and ensure no automatic requests are
/// made to upstream update servers.
@MainActor
final class Updater: NSObject, ObservableObject {
    enum Outcome: Equatable {
        case idle
        case disabled
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed(String)

        var message: String? {
            switch self {
            case .idle:          return nil
            case .disabled:      return L10n.t("Updates are disabled in this private build.")
            case .checking:      return L10n.t("Checking…")
            case .upToDate:      return L10n.t("NotchAgent is up to date.")
            case .found(let v):  return L10n.t("Version \(v) is available.")
            case .unreachable:   return L10n.t("Couldn't reach the update server. NotchAgent will try again on its own — nothing is wrong with this copy.")
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var outcome: Outcome = .disabled
    @Published private(set) var prompt: UpdatePrompt?
    @Published private(set) var pending: String?

    var automatic: Bool {
        get { false }
        set { /* No-op in private build */ }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.20.0"
    }

    var lastChecked: Date? { nil }

    func start() {
        outcome = .disabled
    }

    func reoffer() {}

    func preview() {
        prompt = UpdatePrompt(
            version: Self.nextVersion(after: currentVersion),
            notes: L10n.t("Updates are disabled in this private build."),
            phase: .available
        )
    }

    static func nextVersion(after version: String) -> String {
        var parts = version.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        parts[1] += 1
        parts[2] = 0
        return parts.map(String.init).joined(separator: ".")
    }

    func respond(_ choice: UpdateChoice) {
        prompt = nil
    }

    func progressed(_ phase: UpdatePrompt.Phase) {
        prompt?.phase = phase
    }

    func promptEnded() {
        prompt = nil
    }

    func checkNow() {
        outcome = .disabled
    }

    static let checkTimeout: TimeInterval = 45

    static func outcome(afterTimeoutFrom current: Outcome) -> Outcome {
        guard current == .checking else { return current }
        return .failed(L10n.t("The update check didn't finish."))
    }

    static func outcome(afterCycleFrom current: Outcome, errorCode: Int?) -> Outcome {
        guard current == .checking else { return current }
        guard let errorCode else { return .idle }
        return isUnreachable(errorCode) ? .unreachable : .idle
    }

    static func isUnreachable(_ code: Int) -> Bool {
        code == 1001 || code == -1009 || code == 404
    }
}

/// Update prompt metadata for local view layout compatibility.
struct UpdatePrompt: Equatable {
    enum Phase: Equatable {
        case available
        case downloading(Double?)
        case extracting(Double)
        case installing
    }

    var version: String
    var notes: String
    var phase: Phase

    static func summary(of html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum UpdateChoice: Equatable {
    case install, later, close
}
