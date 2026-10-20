import Foundation

/// Central deny-by-default network policy enforcing:
/// 1. Approved exact HTTPS origins per provider (no wildcard DNS)
/// 2. HTTPS required for all remote traffic (no remote unencrypted HTTP)
/// 3. Remote non-443 port refused except user-authorized custom endpoint base port
/// 4. Ephemeral sessions without shared credential, cookie, or proxy storage
/// 5. Hard redirect rejection on all requests (prevents leaking cookies / auth headers)
/// 6. Strict loopback restrictions for local runtimes and bridges (handling bracketed IPv6)
/// 7. Same-origin validation for custom endpoint usage URLs
/// 8. Refusal of URL userinfo (no embedded credentials in URLs)
/// 9. Combined localhost TLS handling with redirect rejection in a unified delegate
/// 10. Prevention of draft-key transmission on unsaved automatic discovery
/// 11. Sanitized error messages that never leak URL query parameters or secret tokens
public enum NetworkPolicy {

    public enum NetworkScope: Equatable, Hashable, Sendable {
        case amp
        case antigravityRemote
        case antigravityLocal
        case apify
        case claude
        case cursor
        case codex
        case commandcode
        case devin
        case glm
        case githubCopilot
        case grok
        case kilo
        case kimi
        case kiro
        case minimax
        case opencode
        case ollamaCloud
        case ollamaLocal
        case lmstudioLocal
        case costAccounts(provider: String)
        case customEndpoint(baseURL: URL, authorizedUsageURL: URL?)
        case customDiscovery(baseURL: URL)

        public var providerIdentifier: String? {
            switch self {
            case .amp: return "amp"
            case .antigravityRemote, .antigravityLocal: return "antigravity"
            case .apify: return "apify"
            case .claude: return "claude"
            case .cursor: return "cursor"
            case .codex: return "codex"
            case .commandcode: return "commandcode"
            case .devin: return "devin"
            case .glm: return "glm"
            case .githubCopilot: return "copilot"
            case .grok: return "grok"
            case .kilo: return "kilo"
            case .kimi: return "kimi"
            case .kiro: return "kiro"
            case .minimax: return "minimax"
            case .opencode: return "opencode"
            case .ollamaCloud: return "ollama"
            case .ollamaLocal: return "ollama-local"
            case .lmstudioLocal: return "lmstudio"
            case .costAccounts(let provider): return provider
            case .customEndpoint, .customDiscovery: return nil
            }
        }
    }

    public enum PolicyError: LocalizedError, Equatable {
        case missingURL
        case missingHost
        case unapprovedScheme(String)
        case remoteHTTPDisallowed
        case customPortDisallowed(Int)
        case destinationNotAllowed(sanitizedDestination: String)
        case crossOriginUsageDisallowed(base: String, usage: String)
        case nonLoopbackDisallowed(String)
        case userInfoDisallowed
        case providerDisabled(String)
        case draftKeyTransmissionDisallowed

        public var errorDescription: String? {
            switch self {
            case .missingURL:
                return "Network request blocked: missing URL."
            case .missingHost:
                return "Network request blocked: URL has no host."
            case .unapprovedScheme(let scheme):
                return "Network request blocked: unapproved URL scheme '\(scheme)'."
            case .remoteHTTPDisallowed:
                return "Network request blocked: unencrypted HTTP is disallowed for remote services. HTTPS is required."
            case .customPortDisallowed(let port):
                return "Network request blocked: non-standard remote port \(port) is not allowed."
            case .destinationNotAllowed(let sanitized):
                return "Network request blocked by policy: destination '\(sanitized)' is not approved."
            case .crossOriginUsageDisallowed(let base, let usage):
                return "Network request blocked: usage origin '\(usage)' does not share the same origin as base origin '\(base)'."
            case .nonLoopbackDisallowed(let host):
                return "Network request blocked: host '\(host)' is not a valid loopback address."
            case .userInfoDisallowed:
                return "Network request blocked: URL credentials in userinfo are not permitted."
            case .providerDisabled(let provider):
                return "Network request blocked: provider '\(provider)' is disabled."
            case .draftKeyTransmissionDisallowed:
                return "Network request blocked: transmission of draft API keys before saving an endpoint is prohibited."
            }
        }
    }

    public struct Origin: Equatable, Hashable, Sendable {
        public let scheme: String
        public let host: String
        public let port: Int?

        public init(scheme: String, host: String, port: Int? = nil) {
            self.scheme = scheme.lowercased()
            var cleanHost = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanHost.hasPrefix("[") && cleanHost.hasSuffix("]") {
                cleanHost = String(cleanHost.dropFirst().dropLast())
            }
            self.host = cleanHost
            if let port = port {
                if (self.scheme == "https" && port == 443) || (self.scheme == "http" && port == 80) ||
                   (self.scheme == "wss" && port == 443) || (self.scheme == "ws" && port == 80) {
                    self.port = nil
                } else {
                    self.port = port
                }
            } else {
                self.port = nil
            }
        }

        public init?(url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased() else { return nil }
            self.init(scheme: scheme, host: host, port: url.port)
        }

        public var sanitizedString: String {
            if let port = port {
                return "\(scheme)://\(host):\(port)"
            }
            return "\(scheme)://\(host)"
        }
    }

    /// Checks if a hostname represents an authorized loopback interface.
    /// Handles localhost, 127.0.0.0/8, ::1, and bracketed IPv6 representations.
    public static func isLoopback(host: String) -> Bool {
        var lower = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("[") && lower.hasSuffix("]") {
            lower = String(lower.dropFirst().dropLast())
        }
        if lower == "127.0.0.1" || lower == "localhost" || lower == "::1" || lower == "0:0:0:0:0:0:0:1" {
            return true
        }
        // IPv4 loopback range 127.0.0.0/8
        if lower.hasPrefix("127.") {
            let parts = lower.split(separator: ".")
            if parts.count == 4 && parts.allSatisfy({ Int($0) != nil && (0...255).contains(Int($0)!) }) {
                return true
            }
        }
        return false
    }

    /// Approved remote origins for each standard provider scope.
    public static func approvedRemoteOrigins(for scope: NetworkScope) -> Set<Origin> {
        switch scope {
        case .amp:
            return [Origin(scheme: "https", host: "ampcode.com")]
        case .antigravityRemote:
            return [
                Origin(scheme: "https", host: "cloudcode-pa.googleapis.com"),
                Origin(scheme: "https", host: "daily-cloudcode-pa.googleapis.com")
            ]
        case .apify:
            return [Origin(scheme: "https", host: "api.apify.com")]
        case .claude:
            return [Origin(scheme: "https", host: "api.anthropic.com")]
        case .cursor:
            return [Origin(scheme: "https", host: "cursor.com")]
        case .codex:
            return [Origin(scheme: "https", host: "chatgpt.com")]
        case .commandcode:
            return [Origin(scheme: "https", host: "api.commandcode.ai")]
        case .devin:
            return [Origin(scheme: "https", host: "server.self-serve.windsurf.com")]
        case .glm:
            return [
                Origin(scheme: "https", host: "open.bigmodel.cn"),
                Origin(scheme: "https", host: "api.z.ai")
            ]
        case .githubCopilot:
            return [Origin(scheme: "https", host: "api.github.com")]
        case .grok:
            return [
                Origin(scheme: "https", host: "cli-chat-proxy.grok.com"),
                Origin(scheme: "https", host: "accounts.x.ai"),
                Origin(scheme: "https", host: "auth.x.ai")
            ]
        case .kilo:
            return [Origin(scheme: "https", host: "api.kilo.ai")]
        case .kimi:
            return [Origin(scheme: "https", host: "api.kimi.com")]
        case .kiro:
            // Constrained exact known AWS regions, no wildcard DNS allowlist
            var origins: Set<Origin> = [
                Origin(scheme: "https", host: "codewhisperer.us-east-1.amazonaws.com"),
                Origin(scheme: "https", host: "q.eu-central-1.amazonaws.com")
            ]
            if Runtime.isUnderTest {
                origins.insert(Origin(scheme: "https", host: "kiro.test"))
            }
            return origins
        case .minimax:
            return [
                Origin(scheme: "https", host: "api.minimax.io"),
                Origin(scheme: "https", host: "api.minimaxi.com"),
                Origin(scheme: "https", host: "www.minimax.io"),
                Origin(scheme: "https", host: "www.minimaxi.com")
            ]
        case .opencode:
            return [Origin(scheme: "https", host: "opencode.ai")]
        case .ollamaCloud:
            return [Origin(scheme: "https", host: "ollama.com")]
        case .costAccounts(let provider):
            if provider == "claude" {
                return [Origin(scheme: "https", host: "api.anthropic.com")]
            }
            return []
        case .ollamaLocal, .lmstudioLocal, .antigravityLocal:
            // Loopback scopes do not approve remote origins
            return []
        case .customEndpoint(let baseURL, _), .customDiscovery(let baseURL):
            if let origin = Origin(url: baseURL), origin.scheme == "https" {
                return [origin]
            }
            return []
        }
    }

    /// Validates an outbound URLRequest against the network policy.
    public static func validate(request: URLRequest, for scope: NetworkScope) throws {
        guard let url = request.url else {
            throw PolicyError.missingURL
        }
        try validate(url: url, for: scope)
    }

    /// Validates a destination URL against the deny-by-default policy for the given scope.
    public static func validate(url: URL?, for scope: NetworkScope) throws {
        guard !PersistentWrites.isSuspended else { throw URLError(.cancelled) }
        guard let url = url else {
            throw PolicyError.missingURL
        }
        guard let scheme = url.scheme?.lowercased() else {
            throw PolicyError.unapprovedScheme("")
        }
        guard scheme == "https" || scheme == "http" || scheme == "ws" || scheme == "wss" else {
            throw PolicyError.unapprovedScheme(scheme)
        }
        guard let rawHost = url.host, !rawHost.isEmpty else {
            throw PolicyError.missingHost
        }
        let host = rawHost.lowercased()
        if url.user != nil || url.password != nil {
            throw PolicyError.userInfoDisallowed
        }

        let isLocal = isLoopback(host: host)

        // Handle loopback-only scopes
        switch scope {
        case .ollamaLocal, .lmstudioLocal, .antigravityLocal:
            guard isLocal else {
                throw PolicyError.nonLoopbackDisallowed(host)
            }
            return
        default:
            break
        }

        // Loopback traffic for custom endpoints or discovery
        if isLocal {
            switch scope {
            case .customEndpoint(let baseURL, let usageURL):
                guard let baseOrigin = Origin(url: baseURL), isLoopback(host: baseOrigin.host) else {
                    let sanitized = Origin(url: url)?.sanitizedString ?? "\(scheme)://\(host)"
                    throw PolicyError.destinationNotAllowed(sanitizedDestination: sanitized)
                }
                guard let targetOrigin = Origin(url: url),
                      targetOrigin.scheme == baseOrigin.scheme,
                      targetOrigin.host == baseOrigin.host,
                      targetOrigin.port == baseOrigin.port else {
                    let sanitized = Origin(url: url)?.sanitizedString ?? "\(scheme)://\(host)"
                    throw PolicyError.destinationNotAllowed(sanitizedDestination: sanitized)
                }
                if let usage = usageURL, let usageOrigin = Origin(url: usage) {
                    guard usageOrigin == baseOrigin else {
                        throw PolicyError.crossOriginUsageDisallowed(
                            base: baseOrigin.sanitizedString,
                            usage: usageOrigin.sanitizedString
                        )
                    }
                }
                return
            case .customDiscovery(let baseURL):
                guard let baseOrigin = Origin(url: baseURL), isLoopback(host: baseOrigin.host) else {
                    let sanitized = Origin(url: url)?.sanitizedString ?? "\(scheme)://\(host)"
                    throw PolicyError.destinationNotAllowed(sanitizedDestination: sanitized)
                }
                guard let targetOrigin = Origin(url: url),
                      targetOrigin.scheme == baseOrigin.scheme,
                      targetOrigin.host == baseOrigin.host,
                      targetOrigin.port == baseOrigin.port else {
                    let sanitized = Origin(url: url)?.sanitizedString ?? "\(scheme)://\(host)"
                    throw PolicyError.destinationNotAllowed(sanitizedDestination: sanitized)
                }
                return
            default:
                break
            }
        }

        // Remote destinations MUST use https (or wss)
        guard scheme == "https" || scheme == "wss" else {
            throw PolicyError.remoteHTTPDisallowed
        }

        guard let targetOrigin = Origin(url: url) else {
            let sanitized = "\(scheme)://\(host)"
            throw PolicyError.destinationNotAllowed(sanitizedDestination: sanitized)
        }

        // Validate custom endpoints and discovery
        switch scope {
        case .customEndpoint(let baseURL, let usageURL):
            guard let baseOrigin = Origin(url: baseURL) else {
                throw PolicyError.destinationNotAllowed(sanitizedDestination: targetOrigin.sanitizedString)
            }
            guard baseOrigin.scheme == "https" else {
                throw PolicyError.remoteHTTPDisallowed
            }
            // Authorized custom base port is allowed, but must match baseURL
            guard targetOrigin == baseOrigin else {
                throw PolicyError.destinationNotAllowed(sanitizedDestination: targetOrigin.sanitizedString)
            }
            if let usage = usageURL {
                guard let usageOrigin = Origin(url: usage) else {
                    throw PolicyError.destinationNotAllowed(sanitizedDestination: usage.host ?? "")
                }
                guard usageOrigin == baseOrigin else {
                    throw PolicyError.crossOriginUsageDisallowed(
                        base: baseOrigin.sanitizedString,
                        usage: usageOrigin.sanitizedString
                    )
                }
            }
            return
        case .customDiscovery(let baseURL):
            guard let baseOrigin = Origin(url: baseURL) else {
                throw PolicyError.destinationNotAllowed(sanitizedDestination: targetOrigin.sanitizedString)
            }
            guard baseOrigin.scheme == "https" else {
                throw PolicyError.remoteHTTPDisallowed
            }
            guard targetOrigin == baseOrigin else {
                throw PolicyError.destinationNotAllowed(sanitizedDestination: targetOrigin.sanitizedString)
            }
            return
        default:
            break
        }

        // Non-standard remote ports are disallowed for fixed provider scopes
        if let port = url.port, port != 443 {
            throw PolicyError.customPortDisallowed(port)
        }

        // Validate approved remote origins
        let allowed = approvedRemoteOrigins(for: scope)
        guard allowed.contains(targetOrigin) else {
            throw PolicyError.destinationNotAllowed(sanitizedDestination: targetOrigin.sanitizedString)
        }
    }

    /// Combined delegate that:
    /// 1. Denies all HTTP redirects (prevents leaking sensitive tokens/cookies across origins)
    /// 2. Handles loopback TLS certificate trust (accepts self-signed loopback certificates only)
    public final class PolicyDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
        public static let shared = PolicyDelegate()
        private static let antigravity = PolicyDelegate(allowLoopbackTrust: true)
        private let allowLoopbackTrust: Bool

        public init(allowLoopbackTrust: Bool = false) {
            self.allowLoopbackTrust = allowLoopbackTrust
            super.init()
        }

        fileprivate static func scoped(_ scope: NetworkScope) -> PolicyDelegate {
            scope == .antigravityLocal ? antigravity : shared
        }

        public func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Hard reject all redirects
            completionHandler(nil)
        }

        public func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handleChallenge(challenge, completionHandler: completionHandler)
        }

        public func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handleChallenge(challenge, completionHandler: completionHandler)
        }

        private func handleChallenge(
            _ challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let host = challenge.protectionSpace.host
            guard allowLoopbackTrust, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  NetworkPolicy.isLoopback(host: host),
                  let trust = challenge.protectionSpace.serverTrust
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// Constructs an isolated, ephemeral URLSession with no shared credential,
    /// proxy, or cookie storage, and a redirect-rejecting, localhost-trusting delegate.
    public static func makeSession(
        for scope: NetworkScope,
        delegate: URLSessionDelegate? = nil
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]

        let sessionDelegate: URLSessionDelegate = delegate ?? PolicyDelegate.scoped(scope)
        return URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }

    /// Task delegate that can be passed to `session.data(for: request, delegate: ...)`
    /// to ensure redirect rejection and localhost TLS verification work even when
    /// a custom session is injected in tests.
    public static func taskDelegate(for scope: NetworkScope) -> URLSessionTaskDelegate {
        PolicyDelegate.scoped(scope)
    }
}
