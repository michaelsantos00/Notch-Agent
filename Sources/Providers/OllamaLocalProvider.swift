import Foundation

@MainActor
final class OllamaLocalProvider: UsageProvider {
    nonisolated let id = "ollama-local"
    nonisolated let displayName = "Ollama"
    nonisolated let glyph = ProviderGlyph.ollamaLocal
    nonisolated let kind = ProviderKind.localRuntime

    nonisolated var isVisibleWhenAbsent: Bool { false }
    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "com.electron.ollama", name: "Ollama")
    }

    var endpoint: URL
    private let session: URLSession

    init(endpoint: URL = URL(string: OllamaEndpoint.defaultAddress)!, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.session = session ?? Self.makeSession()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/ps"))
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try NetworkPolicy.validate(request: request, for: .ollamaLocal)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NetworkPolicy.taskDelegate(for: .ollamaLocal))
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OllamaError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OllamaError.http(status) }
        let reading = try OllamaLocalUsage.parse(data)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: [],
                                kind: kind, localRuntime: reading)
    }

    nonisolated static func makeSession() -> URLSession {
        NetworkPolicy.makeSession(for: .ollamaLocal)
    }
}

typealias OllamaRedirectPolicy = NetworkPolicy.PolicyDelegate
