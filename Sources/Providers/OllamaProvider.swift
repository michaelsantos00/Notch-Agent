import Foundation
import os

/// Where Ollama's cloud usage is read from. The two report different things,
/// because since October 2026 Ollama publishes them in different places:
enum OllamaUsageSource: String, CaseIterable, Codable, Sendable {
    /// `GET /api/usage` with an API key: request counts, no percentage.
    case apiKey
    /// ollama.com/settings through a browser's sign-in: the session (5-hour)
    /// and weekly percentages, with their exact resets.
    case browser
}

/// The Ollama choices the provider reads on every fetch — from the store, not
/// the `Preferences` object, which is main-actor state.
struct OllamaCloudSource: Equatable, Sendable {
    static let automatic = "auto"

    var usage: OllamaUsageSource
    /// `automatic`, or the `BrowserCookies.Store.id` the user picked.
    var cookieStore: String

    static func stored() -> OllamaCloudSource {
        OllamaCloudSource(usage: Preferences.storedOllamaUsageSource(),
                          cookieStore: Preferences.storedOllamaCookieStore())
    }
}

/// Reads Ollama cloud usage, either from `https://ollama.com/api/usage` with
/// an API key the user provides in Settings or exports as `OLLAMA_API_KEY`, or
/// from the ollama.com settings page with the sign-in of a browser on this Mac.
///
/// The API key is the only credential any provider *owns*: it is stored in the
/// login keychain under a service no other app uses, and sign-out deletes it.
/// The browser's sign-in is borrowed, read-only, like every other provider's.
actor OllamaProvider: UsageProvider {
    nonisolated let id = "ollama"
    nonisolated let displayName = "Ollama"
    nonisolated let glyph = ProviderGlyph.ollama

    /// Thirty days of day buckets: the widest range the API allows, and enough
    /// to derive today and the last week from the one request.
    private let endpoint = URL(string: "https://ollama.com/api/usage?range=30d")!
    private let session: URLSession
    private let home: URL
    private let source: @Sendable () -> OllamaCloudSource
    private let password: @Sendable (BrowserCookies.Engine) throws -> String
    private let browserState = BrowserState()

    init(session: URLSession? = nil,
         home: URL = URL(fileURLWithPath: NSHomeDirectory()),
         source: @escaping @Sendable () -> OllamaCloudSource = OllamaCloudSource.stored,
         password: @escaping @Sendable (BrowserCookies.Engine) throws -> String = BrowserCookies.keychainPassword) {
        self.session = session ?? NetworkPolicy.makeSession(for: .ollamaCloud)
        self.home = home
        self.source = source
        self.password = password
    }

    nonisolated var signInRoute: SignInRoute {
        switch source().usage {
        case .apiKey:
            return .guidance(L10n.t("Enter an Ollama API key below, or export OLLAMA_API_KEY in your shell."))
        case .browser:
            return .guidance(L10n.t("Sign in to ollama.com in your browser, then choose that browser below."))
        }
    }

    nonisolated func account() -> ProviderAccount? {
        let usage = source().usage
        guard usage == .browser || OllamaCredentials.isPresent else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: usage == .browser ? L10n.t("ollama.com sign-in") : "Ollama",
            manageURL: URL(string: "https://ollama.com/settings")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let source = source()
        switch source.usage {
        case .apiKey: return try await fetchCounts()
        case .browser: return try await fetchPage(source)
        }
    }

    // MARK: - API key: request counts

    private func fetchCounts() async throws -> ProviderSnapshot {
        guard let key = OllamaCredentials.load() else { throw UsageProviderError.needsAuth }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        try NetworkPolicy.validate(request: request, for: .ollamaCloud)
        let (data, response) = try await session.data(for: request, delegate: NetworkPolicy.taskDelegate(for: .ollamaCloud))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        let result = try OllamaUsage.parse(body)
        return snapshot(result)
    }

    // MARK: - Browser: the settings page

    private func fetchPage(_ source: OllamaCloudSource) async throws -> ProviderSnapshot {
        let cookie = try browserCookie(for: source)

        var request = URLRequest(url: OllamaWebUsage.page)
        request.setValue("\(OllamaWebUsage.sessionCookie)=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        try NetworkPolicy.validate(request: request, for: .ollamaCloud)
        let (data, response) = try await session.data(for: request, delegate: NetworkPolicy.taskDelegate(for: .ollamaCloud))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // A sign-in that has lapsed is answered with a redirect to sign in —
        // refused here, as every redirect is — or with the signed-out page.
        do {
            if status == 401 || status == 403 || (300..<400).contains(status) {
                throw UsageProviderError.needsAuth
            }
            guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }
            return snapshot(try OllamaWebUsage.parse(String(decoding: data, as: UTF8.self)))
        } catch UsageProviderError.needsAuth {
            browserState.forgetCookie()
            throw UsageProviderError.needsAuth
        }
    }

    /// The chosen browser's ollama.com sign-in, kept in memory once read so the
    /// browser's files — and for Chromium, the keychain — are visited only when
    /// the choice changes or the sign-in stops working.
    private func browserCookie(for source: OllamaCloudSource) throws -> String {
        if let held = browserState.cookie(for: source.cookieStore) { return held }

        let sessions = BrowserCookies.sessions(named: OllamaWebUsage.sessionCookie,
                                               host: OllamaWebUsage.host, home: home)
        let chosen = source.cookieStore == OllamaCloudSource.automatic
            ? BrowserCookies.freshest(sessions)
            : sessions.first { $0.store.id == source.cookieStore }
        guard let chosen else {
            let safariMayHaveIt = source.cookieStore == OllamaCloudSource.automatic || source.cookieStore == "safari"
            if safariMayHaveIt && BrowserCookies.safariNeedsFullDiskAccess(home: home) {
                throw UsageProviderError.apiError(L10n.t("Safari needs Full Disk Access to share its ollama.com sign-in."))
            }
            throw UsageProviderError.needsAuth
        }

        do {
            let value = try BrowserCookies.value(named: OllamaWebUsage.sessionCookie, host: OllamaWebUsage.host,
                                                 in: chosen.store) { engine in
                // A declined keychain dialogue is remembered, not re-raised on
                // every poll; "Allow access…" clears it for a deliberate retry.
                guard !browserState.isRefused(engine) else { throw BrowserCookies.ReadError.keyUnavailable }
                do { return try password(engine) } catch {
                    browserState.refuse(engine)
                    throw error
                }
            }
            browserState.hold(value, for: source.cookieStore)
            return value
        } catch BrowserCookies.ReadError.keyUnavailable {
            throw UsageProviderError.accessDenied
        } catch BrowserCookies.ReadError.needsFullDiskAccess {
            throw UsageProviderError.apiError(L10n.t("Safari needs Full Disk Access to share its ollama.com sign-in."))
        } catch {
            throw UsageProviderError.needsAuth
        }
    }

    private func snapshot(_ result: OllamaUsage.Result) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: result.windows,
            headlineID: result.headlineID,
            weeklyID: "weekly"
        )
    }

    nonisolated func signOut() async {
        OllamaCredentials.delete()
        browserState.forgetCookie()
    }

    nonisolated func forgetCachedCredential() {
        OllamaCredentials.forgetCached()
        browserState.reset()
    }
}

/// The borrowed sign-in and any declined keychain dialogue, behind a lock:
/// "Allow access…" and sign-out reach them from outside the actor.
private final class BrowserState: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (store: String, cookie: String)?
    private var refused: [BrowserCookies.Engine] = []

    func cookie(for store: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let held, held.store == store else { return nil }
        return held.cookie
    }

    func hold(_ cookie: String, for store: String) {
        lock.lock(); held = (store, cookie); lock.unlock()
    }

    func forgetCookie() {
        lock.lock(); held = nil; lock.unlock()
    }

    func isRefused(_ engine: BrowserCookies.Engine) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return refused.contains(engine)
    }

    func refuse(_ engine: BrowserCookies.Engine) {
        lock.lock(); refused.append(engine); lock.unlock()
    }

    func reset() {
        lock.lock(); held = nil; refused = []; lock.unlock()
    }
}
