import XCTest
@testable import NotchAgent

final class NetworkPolicyTests: XCTestCase {

    // MARK: - Approved Origins & Scope Verification

    func testApprovedRemoteOriginsPerProvider() {
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .amp),
            [NetworkPolicy.Origin(scheme: "https", host: "ampcode.com")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .antigravityRemote),
            [
                NetworkPolicy.Origin(scheme: "https", host: "cloudcode-pa.googleapis.com"),
                NetworkPolicy.Origin(scheme: "https", host: "daily-cloudcode-pa.googleapis.com")
            ]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .apify),
            [NetworkPolicy.Origin(scheme: "https", host: "api.apify.com")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .claude),
            [NetworkPolicy.Origin(scheme: "https", host: "api.anthropic.com")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .cursor),
            [NetworkPolicy.Origin(scheme: "https", host: "cursor.com")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .codex),
            [NetworkPolicy.Origin(scheme: "https", host: "chatgpt.com")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .commandcode),
            [NetworkPolicy.Origin(scheme: "https", host: "api.commandcode.ai")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .devin),
            [NetworkPolicy.Origin(scheme: "https", host: "server.self-serve.windsurf.com")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .glm),
            [
                NetworkPolicy.Origin(scheme: "https", host: "open.bigmodel.cn"),
                NetworkPolicy.Origin(scheme: "https", host: "api.z.ai")
            ]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .githubCopilot),
            [NetworkPolicy.Origin(scheme: "https", host: "api.github.com")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .grok),
            [
                NetworkPolicy.Origin(scheme: "https", host: "cli-chat-proxy.grok.com"),
                NetworkPolicy.Origin(scheme: "https", host: "accounts.x.ai"),
                NetworkPolicy.Origin(scheme: "https", host: "auth.x.ai")
            ]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .kilo),
            [NetworkPolicy.Origin(scheme: "https", host: "api.kilo.ai")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .kimi),
            [NetworkPolicy.Origin(scheme: "https", host: "api.kimi.com")]
        )
        var expectedKiro: Set<NetworkPolicy.Origin> = [
            NetworkPolicy.Origin(scheme: "https", host: "codewhisperer.us-east-1.amazonaws.com"),
            NetworkPolicy.Origin(scheme: "https", host: "q.eu-central-1.amazonaws.com")
        ]
        if Runtime.isUnderTest {
            expectedKiro.insert(NetworkPolicy.Origin(scheme: "https", host: "kiro.test"))
        }
        XCTAssertEqual(NetworkPolicy.approvedRemoteOrigins(for: .kiro), expectedKiro)
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .minimax),
            [
                NetworkPolicy.Origin(scheme: "https", host: "api.minimax.io"),
                NetworkPolicy.Origin(scheme: "https", host: "api.minimaxi.com"),
                NetworkPolicy.Origin(scheme: "https", host: "www.minimax.io"),
                NetworkPolicy.Origin(scheme: "https", host: "www.minimaxi.com")
            ]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .opencode),
            [NetworkPolicy.Origin(scheme: "https", host: "opencode.ai")]
        )
        XCTAssertEqual(
            NetworkPolicy.approvedRemoteOrigins(for: .ollamaCloud),
            [NetworkPolicy.Origin(scheme: "https", host: "ollama.com")]
        )

        // Loopback scopes must approve no remote origins
        XCTAssertTrue(NetworkPolicy.approvedRemoteOrigins(for: .ollamaLocal).isEmpty)
        XCTAssertTrue(NetworkPolicy.approvedRemoteOrigins(for: .lmstudioLocal).isEmpty)
        XCTAssertTrue(NetworkPolicy.approvedRemoteOrigins(for: .antigravityLocal).isEmpty)
    }

    func testProviderScopeIdentifiers() {
        XCTAssertEqual(NetworkPolicy.NetworkScope.amp.providerIdentifier, "amp")
        XCTAssertEqual(NetworkPolicy.NetworkScope.antigravityRemote.providerIdentifier, "antigravity")
        XCTAssertEqual(NetworkPolicy.NetworkScope.antigravityLocal.providerIdentifier, "antigravity")
        XCTAssertEqual(NetworkPolicy.NetworkScope.apify.providerIdentifier, "apify")
        XCTAssertEqual(NetworkPolicy.NetworkScope.claude.providerIdentifier, "claude")
        XCTAssertEqual(NetworkPolicy.NetworkScope.cursor.providerIdentifier, "cursor")
        XCTAssertEqual(NetworkPolicy.NetworkScope.codex.providerIdentifier, "codex")
        XCTAssertEqual(NetworkPolicy.NetworkScope.commandcode.providerIdentifier, "commandcode")
        XCTAssertEqual(NetworkPolicy.NetworkScope.devin.providerIdentifier, "devin")
        XCTAssertEqual(NetworkPolicy.NetworkScope.glm.providerIdentifier, "glm")
        XCTAssertEqual(NetworkPolicy.NetworkScope.githubCopilot.providerIdentifier, "copilot")
        XCTAssertEqual(NetworkPolicy.NetworkScope.grok.providerIdentifier, "grok")
        XCTAssertEqual(NetworkPolicy.NetworkScope.kilo.providerIdentifier, "kilo")
        XCTAssertEqual(NetworkPolicy.NetworkScope.kimi.providerIdentifier, "kimi")
        XCTAssertEqual(NetworkPolicy.NetworkScope.kiro.providerIdentifier, "kiro")
        XCTAssertEqual(NetworkPolicy.NetworkScope.minimax.providerIdentifier, "minimax")
        XCTAssertEqual(NetworkPolicy.NetworkScope.opencode.providerIdentifier, "opencode")
        XCTAssertEqual(NetworkPolicy.NetworkScope.ollamaCloud.providerIdentifier, "ollama")
        XCTAssertEqual(NetworkPolicy.NetworkScope.ollamaLocal.providerIdentifier, "ollama-local")
        XCTAssertEqual(NetworkPolicy.NetworkScope.lmstudioLocal.providerIdentifier, "lmstudio")
        XCTAssertEqual(NetworkPolicy.NetworkScope.costAccounts(provider: "claude").providerIdentifier, "claude")
    }

    // MARK: - Validation Success for Approved Providers

    func testValidationPassesForApprovedOrigins() {
        let cases: [(String, NetworkPolicy.NetworkScope)] = [
            ("https://ampcode.com/v1/models", .amp),
            ("https://cloudcode-pa.googleapis.com/v1/quota", .antigravityRemote),
            ("https://daily-cloudcode-pa.googleapis.com/v1/quota", .antigravityRemote),
            ("https://api.apify.com/v2/users/me", .apify),
            ("https://api.anthropic.com/v1/organizations", .claude),
            ("https://cursor.com/api/usage", .cursor),
            ("https://chatgpt.com/backend-api/latents/limits", .codex),
            ("https://api.commandcode.ai/v1/tokens", .commandcode),
            ("https://server.self-serve.windsurf.com/v1/metrics", .devin),
            ("https://open.bigmodel.cn/api/paas/v4/user", .glm),
            ("https://api.z.ai/v1/balance", .glm),
            ("https://api.github.com/copilot_internal/usage", .githubCopilot),
            ("https://cli-chat-proxy.grok.com/usage", .grok),
            ("https://accounts.x.ai/profile", .grok),
            ("https://auth.x.ai/token", .grok),
            ("https://api.kilo.ai/v1/quota", .kilo),
            ("https://api.kimi.com/v1/users/me", .kimi),
            ("https://codewhisperer.us-east-1.amazonaws.com", .kiro),
            ("https://q.eu-central-1.amazonaws.com", .kiro),
            ("https://api.minimax.io/v1/token_plan/remains", .minimax),
            ("https://api.minimaxi.com/v1/token_plan/remains", .minimax),
            ("https://www.minimax.io/user-center", .minimax),
            ("https://www.minimaxi.com/user-center", .minimax),
            ("https://opencode.ai/zen/go/v1/usage", .opencode),
            ("https://opencode.ai/inference/go/v1/usage", .opencode),
            ("https://ollama.com/api/user", .ollamaCloud),
            ("https://api.anthropic.com/v1/organizations", .costAccounts(provider: "claude"))
        ]

        for (urlString, scope) in cases {
            guard let url = URL(string: urlString) else {
                XCTFail("Malformed test URL: \(urlString)")
                continue
            }
            XCTAssertNoThrow(try NetworkPolicy.validate(url: url, for: scope), "Expected success for \(urlString)")
            XCTAssertNoThrow(try NetworkPolicy.validate(request: URLRequest(url: url), for: scope))
        }
    }

    // MARK: - Kiro Constrained Regions (No Wildcard DNS)

    func testKiroConstrainedKnownAWSRegions() {
        // Valid exact origins
        XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "https://codewhisperer.us-east-1.amazonaws.com"), for: .kiro))
        XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "https://q.eu-central-1.amazonaws.com"), for: .kiro))

        // Non-approved AWS regions or subdomains must be rejected (no *.amazonaws.com wildcard)
        let forbidden = [
            "https://codewhisperer.us-west-2.amazonaws.com",
            "https://codewhisperer.ap-southeast-1.amazonaws.com",
            "https://q.us-east-1.amazonaws.com",
            "https://s3.amazonaws.com",
            "https://attacker.amazonaws.com",
            "https://codewhisperer.us-east-1.amazonaws.com.attacker.com"
        ]
        for urlString in forbidden {
            let url = URL(string: urlString)!
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .kiro), "Expected failure for \(urlString)") { error in
                guard case NetworkPolicy.PolicyError.destinationNotAllowed = error else {
                    XCTFail("Expected destinationNotAllowed for \(urlString), got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Rejection of Forbidden Domains, Suffixes & Slashes

    func testRejectsSuffixAndAttackerDomains() {
        let forbidden = [
            "https://api.anthropic.com.attacker.com",
            "https://attacker-api.anthropic.com",
            "https://evil.com/api.anthropic.com",
            "https://opencode.ai.attacker.org",
            "https://ampcode.com.hacker.io",
            "https://api.apify.com.phishing.net"
        ]

        for urlString in forbidden {
            let url = URL(string: urlString)!
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .claude))
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .opencode))
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .amp))
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .apify))
        }
    }

    // MARK: - Rejection of Unapproved Schemes

    func testRejectsUnapprovedSchemes() {
        let forbidden = [
            "ftp://api.anthropic.com/file",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/plain;base64,SGVsbG8=",
            "gopher://api.anthropic.com"
        ]
        for urlString in forbidden {
            let url = URL(string: urlString)!
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .claude)) { error in
                guard case NetworkPolicy.PolicyError.unapprovedScheme = error else {
                    XCTFail("Expected unapprovedScheme for \(urlString), got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Rejection of Remote Plain HTTP

    func testRejectsRemotePlainHTTP() {
        let remotes = [
            "http://api.anthropic.com/v1/models",
            "http://opencode.ai/zen/go/v1/usage",
            "http://api.apify.com/v2/users/me",
            "http://cursor.com/api/usage",
            "http://codewhisperer.us-east-1.amazonaws.com"
        ]
        for urlString in remotes {
            let url = URL(string: urlString)!
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .claude)) { error in
                XCTAssertEqual(error as? NetworkPolicy.PolicyError, .remoteHTTPDisallowed)
            }
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .opencode)) { error in
                XCTAssertEqual(error as? NetworkPolicy.PolicyError, .remoteHTTPDisallowed)
            }
        }
    }

    // MARK: - Rejection of Non-Standard Remote Ports

    func testRejectsNonStandardRemotePortsForProviders() {
        let customPorts = [
            "https://api.anthropic.com:8080/v1/models",
            "https://api.anthropic.com:8443/v1/models",
            "https://opencode.ai:9000/zen/go/v1/usage",
            "https://api.github.com:22/user"
        ]
        for urlString in customPorts {
            let url = URL(string: urlString)!
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .claude)) { error in
                guard case NetworkPolicy.PolicyError.customPortDisallowed = error else {
                    XCTFail("Expected customPortDisallowed for \(urlString), got \(error)")
                    return
                }
            }
        }

        // Port 443 is explicitly allowed
        XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "https://api.anthropic.com:443/v1/models"), for: .claude))
    }

    // MARK: - Rejection of Userinfo Credentials

    func testRejectsUserInfoCredentialsInURLs() {
        let withCredentials = [
            "https://user:password@api.anthropic.com/v1/models",
            "https://token@api.github.com/user",
            "http://admin:secret@127.0.0.1:11434/api/tags",
            "ws://user:pass@127.0.0.1:1234/rpc"
        ]
        for urlString in withCredentials {
            let url = URL(string: urlString)!
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .claude)) { error in
                XCTAssertEqual(error as? NetworkPolicy.PolicyError, .userInfoDisallowed)
            }
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .ollamaLocal)) { error in
                XCTAssertEqual(error as? NetworkPolicy.PolicyError, .userInfoDisallowed)
            }
            XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: .lmstudioLocal)) { error in
                XCTAssertEqual(error as? NetworkPolicy.PolicyError, .userInfoDisallowed)
            }
        }
    }

    // MARK: - Strict Loopback Validation (IPv4, IPv6, localhost)

    func testLoopbackClassification() {
        // Valid IPv4 loopback (127.0.0.0/8)
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "127.0.0.1"))
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "127.0.0.2"))
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "127.1.2.3"))
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "127.255.255.254"))

        // Named loopback
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "localhost"))
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "LOCALHOST"))

        // IPv6 loopback and bracketed forms
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "::1"))
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "[::1]"))
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "0:0:0:0:0:0:0:1"))
        XCTAssertTrue(NetworkPolicy.isLoopback(host: "[0:0:0:0:0:0:0:1]"))

        // Forbidden non-loopback addresses
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "128.0.0.1"))
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "192.168.1.1"))
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "10.0.0.1"))
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "172.16.0.1"))
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "localhost.attacker.com"))
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "127.0.0.1.attacker.com"))
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "example.com"))
        XCTAssertFalse(NetworkPolicy.isLoopback(host: "::2"))
    }

    func testLoopbackOnlyScopesEnforceLocalhost() {
        let localScopes: [NetworkPolicy.NetworkScope] = [.ollamaLocal, .lmstudioLocal, .antigravityLocal]

        for scope in localScopes {
            // Valid loopback with custom ports and schemes (http and ws)
            XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "http://127.0.0.1:11434/api/tags"), for: scope))
            XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "http://localhost:1234/v1/models"), for: scope))
            XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "http://[::1]:8080/rpc"), for: scope))

            if scope == .lmstudioLocal {
                XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "ws://127.0.0.1:1234/api/v1"), for: scope))
                XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "ws://localhost:1234/api/v1"), for: scope))
            }

            // Remote hostnames must be rejected
            let forbidden = [
                "https://api.anthropic.com",
                "http://evil.com:11434",
                "http://192.168.1.50:11434",
                "http://10.0.0.2:1234"
            ]
            for bad in forbidden {
                let url = URL(string: bad)!
                XCTAssertThrowsError(try NetworkPolicy.validate(url: url, for: scope), "Expected failure for \(bad)") { error in
                    guard case NetworkPolicy.PolicyError.nonLoopbackDisallowed = error else {
                        XCTFail("Expected nonLoopbackDisallowed for \(bad), got \(error)")
                        return
                    }
                }
            }
        }
    }

    // MARK: - Custom Endpoint Validation & Same-Origin Usage

    func testCustomEndpointRemoteOriginValidation() {
        let baseURL = URL(string: "https://my-llm.corp.internal:8443/v1")!
        let scope = NetworkPolicy.NetworkScope.customEndpoint(baseURL: baseURL, authorizedUsageURL: nil)

        // Matching host, port, scheme is allowed
        XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "https://my-llm.corp.internal:8443/v1/models"), for: scope))
        XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "https://my-llm.corp.internal:8443/chat/completions"), for: scope))

        // Different port must be rejected
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "https://my-llm.corp.internal:443/v1/models"), for: scope))

        // Different host must be rejected
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "https://attacker.com:8443/v1/models"), for: scope))

        // Plain HTTP must be rejected for remote custom endpoint
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "http://my-llm.corp.internal:8443/v1/models"), for: scope))
    }

    func testCustomEndpointLoopbackValidation() {
        let baseURL = URL(string: "http://127.0.0.1:8000/v1")!
        let scope = NetworkPolicy.NetworkScope.customEndpoint(baseURL: baseURL, authorizedUsageURL: nil)

        // Same loopback port is allowed
        XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "http://127.0.0.1:8000/v1/models"), for: scope))

        // Different port is rejected (must match baseURL origin)
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "http://127.0.0.1:9000/v1/models"), for: scope))

        // Remote host is rejected
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "http://remote.com:8000/v1/models"), for: scope))
    }

    func testCustomEndpointSameOriginUsageEnforcement() {
        let baseURL = URL(string: "https://custom.ai:8443/v1")!
        let matchingUsage = URL(string: "https://custom.ai:8443/billing/usage")!
        let crossOriginUsage = URL(string: "https://billing.other.ai:8443/usage")!
        let crossPortUsage = URL(string: "https://custom.ai:9443/usage")!
        let crossSchemeUsage = URL(string: "http://custom.ai:8443/usage")!

        // Same origin usage is accepted
        let validScope = NetworkPolicy.NetworkScope.customEndpoint(baseURL: baseURL, authorizedUsageURL: matchingUsage)
        XCTAssertNoThrow(try NetworkPolicy.validate(url: URL(string: "https://custom.ai:8443/v1/models"), for: validScope))

        // Cross origin usage is rejected
        let invalidScope1 = NetworkPolicy.NetworkScope.customEndpoint(baseURL: baseURL, authorizedUsageURL: crossOriginUsage)
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "https://custom.ai:8443/v1/models"), for: invalidScope1)) { error in
            guard case NetworkPolicy.PolicyError.crossOriginUsageDisallowed = error else {
                XCTFail("Expected crossOriginUsageDisallowed, got \(error)")
                return
            }
        }

        let invalidScope2 = NetworkPolicy.NetworkScope.customEndpoint(baseURL: baseURL, authorizedUsageURL: crossPortUsage)
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "https://custom.ai:8443/v1/models"), for: invalidScope2))

        let invalidScope3 = NetworkPolicy.NetworkScope.customEndpoint(baseURL: baseURL, authorizedUsageURL: crossSchemeUsage)
        XCTAssertThrowsError(try NetworkPolicy.validate(url: URL(string: "https://custom.ai:8443/v1/models"), for: invalidScope3))
    }

    func testCustomEndpointModelURLValidation() {
        // Valid HTTPS remote
        XCTAssertTrue(CustomEndpoint.isValidURL("https://api.openai.com/v1"))
        XCTAssertTrue(CustomEndpoint.isValidURL("https://custom.internal:8443/v1"))

        // Valid loopback HTTP
        XCTAssertTrue(CustomEndpoint.isValidURL("http://127.0.0.1:11434"))
        XCTAssertTrue(CustomEndpoint.isValidURL("http://localhost:8000"))
        XCTAssertTrue(CustomEndpoint.isValidURL("http://[::1]:8080"))

        // Invalid: remote plain HTTP
        XCTAssertFalse(CustomEndpoint.isValidURL("http://remote.ai/v1"))
        XCTAssertFalse(CustomEndpoint.isValidURL("http://api.openai.com"))

        // Invalid: userinfo credentials in URL
        XCTAssertFalse(CustomEndpoint.isValidURL("https://key:secret@custom.ai"))
        XCTAssertFalse(CustomEndpoint.isValidURL("http://user:pass@127.0.0.1:8000"))

        // Invalid: unapproved scheme
        XCTAssertFalse(CustomEndpoint.isValidURL("ftp://custom.ai"))
        XCTAssertFalse(CustomEndpoint.isValidURL("file:///path/to/api"))
        XCTAssertFalse(CustomEndpoint.isValidURL("javascript:alert(1)"))
    }

    // MARK: - Hard Redirect Rejection in PolicyDelegate

    func testPolicyDelegateHardRejectionOfRedirects() {
        let delegate = NetworkPolicy.PolicyDelegate.shared
        let session = URLSession(configuration: .ephemeral)
        let originalURL = URL(string: "https://api.anthropic.com/v1/organizations")!
        let task = session.dataTask(with: originalURL)

        let redirectResponse = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://attacker.com/leak"]
        )!
        let newRequest = URLRequest(url: URL(string: "https://attacker.com/leak")!)

        let expectation = expectation(description: "Completion handler called with nil")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirectResponse, newRequest: newRequest) { request in
            XCTAssertNil(request, "Redirect must be completely blocked (completion handler receives nil)")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Ephemeral Session Factory Isolation

    func testEphemeralSessionFactoryIsolation() {
        let session = NetworkPolicy.makeSession(for: .claude)
        let config = session.configuration

        XCTAssertNil(config.httpCookieStorage, "Ephemeral session must have nil cookie storage")
        XCTAssertNil(config.urlCredentialStorage, "Ephemeral session must have nil credential storage")
        XCTAssertFalse(config.httpShouldSetCookies, "Session must not set cookies")
        XCTAssertNil(config.urlCache, "Session must have nil URL cache")
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(config.connectionProxyDictionary?.count, 0, "Proxy dictionary should be empty")
    }

    // MARK: - Sanitized Diagnostic Logging

    func testSanitizedDescriptionDoesNotLeakSecretsOrFailingURL() {
        XCTAssertEqual(UsageStore.sanitizedDescription(for: UsageProviderError.apiError("fixture-secret")), "apiError")
        XCTAssertEqual(UsageStore.sanitizedDescription(for: UsageProviderError.nothingMetered("fixture-secret")), "nothingMetered")
        // URLError should not dump failing URL query parameters
        let queryURL = URL(string: "https://api.anthropic.com/v1/test?token=SECRET_12345&key=SUPER_SECRET")!
        let urlError = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: queryURL,
            NSURLErrorFailingURLStringErrorKey: queryURL.absoluteString
        ])
        let sanitized = UsageStore.sanitizedDescription(for: urlError)
        XCTAssertFalse(sanitized.contains("SECRET"), "Sanitized error must not contain secret query tokens")
        XCTAssertFalse(sanitized.contains("SUPER_SECRET"), "Sanitized error must not contain secret query tokens")
        XCTAssertEqual(sanitized, "URLError(code: -1001)")

        // PolicyError localized descriptions are sanitized
        let policyError = NetworkPolicy.PolicyError.destinationNotAllowed(sanitizedDestination: "https://evil.com")
        XCTAssertEqual(
            UsageStore.sanitizedDescription(for: policyError),
            "Network request blocked by policy: destination 'https://evil.com' is not approved."
        )

        // General NSError should only emit domain and code
        let nsError = NSError(domain: "CustomDomain", code: 42, userInfo: ["SecretData": "top_secret_token"])
        let nsSanitized = UsageStore.sanitizedDescription(for: nsError)
        XCTAssertFalse(nsSanitized.contains("top_secret_token"))
        XCTAssertEqual(nsSanitized, "CustomDomain code 42")
    }

    // MARK: - Disabled Provider Safety

    func testCostAccountsForDisabledProviderApprovedOrigins() {
        // Unknown or disabled providers get empty approved origins
        let emptyOrigins = NetworkPolicy.approvedRemoteOrigins(for: .costAccounts(provider: "unknown_provider"))
        XCTAssertTrue(emptyOrigins.isEmpty)

        // Claude gets exact Anthropic origin
        let claudeOrigins = NetworkPolicy.approvedRemoteOrigins(for: .costAccounts(provider: "claude"))
        XCTAssertEqual(claudeOrigins, [NetworkPolicy.Origin(scheme: "https", host: "api.anthropic.com")])
    }

    // MARK: - WebSocket URL Pre-Validation

    func testWebSocketPreValidation() {
        // Localhost ws is approved for lmstudioLocal
        let localWS = URL(string: "ws://127.0.0.1:1234/rpc")!
        XCTAssertNoThrow(try NetworkPolicy.validate(url: localWS, for: .lmstudioLocal))

        // Remote ws is blocked
        let remoteWS = URL(string: "ws://attacker.com:1234/rpc")!
        XCTAssertThrowsError(try NetworkPolicy.validate(url: remoteWS, for: .lmstudioLocal)) { error in
            guard case NetworkPolicy.PolicyError.nonLoopbackDisallowed = error else {
                XCTFail("Expected nonLoopbackDisallowed, got \(error)")
                return
            }
        }
    }
}
