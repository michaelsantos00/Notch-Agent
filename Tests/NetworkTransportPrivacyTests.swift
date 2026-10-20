import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import NotchAgent

final class NetworkTransportPrivacyTests: XCTestCase {
    func testCustomUsageRejectsRedirectWithoutForwardingCookieOrAPIKey() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let sinkRequests = RequestCapture()
        let sink = try await server(group: group, capture: sinkRequests, location: nil)
        let sourceRequests = RequestCapture()
        let location = "http://localhost:\(sink.localAddress!.port!)/collect"
        let source = try await server(group: group, capture: sourceRequests, location: location)
        let base = "http://127.0.0.1:\(source.localAddress!.port!)"
        // Deliberately inject a normal session: the production request must still
        // supply its redirect guard rather than relying on the session factory.
        let session = URLSession(configuration: .ephemeral)
        let network = CustomEndpointNetwork(session: session)
        for header in ["Cookie", "X-Api-Key"] {
            do {
                _ = try await network.fetchJSONUsage(baseURL: base, usageURL: base + "/usage",
                    apiKey: "fixture-secret", headerKey: header, recordsPath: "",
                    modelField: "model", tokenField: "tokens", modelFilter: nil)
                XCTFail("A redirect must not produce a usage reading")
            } catch { /* the original 302 is rejected */ }
        }
        XCTAssertEqual(sourceRequests.headers.count, 2)
        XCTAssertEqual(sourceRequests.headers[0].first(name: "Cookie"), "fixture-secret")
        XCTAssertEqual(sourceRequests.headers[1].first(name: "X-Api-Key"), "fixture-secret")
        XCTAssertTrue(sinkRequests.headers.isEmpty, "Redirect target must receive no request or credentials")
        session.invalidateAndCancel()
        try await source.close().get()
        try await sink.close().get()
        try await group.shutdownGracefully()
    }

    func testCrossOriginUsageIsBlockedBeforeSendingCredentials() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let capture = RequestCapture()
        let target = try await server(group: group, capture: capture, location: nil)
        let usage = "http://127.0.0.1:\(target.localAddress!.port!)/usage"
        let network = CustomEndpointNetwork()
        do {
            _ = try await network.fetchJSONUsage(baseURL: "http://localhost:1", usageURL: usage,
                apiKey: "fixture-secret", headerKey: "X-Api-Key", recordsPath: "",
                modelField: "model", tokenField: "tokens", modelFilter: nil)
            XCTFail("Cross-origin usage must be blocked")
        } catch {
            XCTAssertTrue(error is NetworkPolicy.PolicyError)
        }
        XCTAssertTrue(capture.headers.isEmpty)
        try await target.close().get()
        try await group.shutdownGracefully()
    }

    private func server(group: MultiThreadedEventLoopGroup, capture: RequestCapture,
                        location: String?) async throws -> Channel {
        try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(PrivacyHTTPHandler(capture: capture, location: location))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [HTTPHeaders] = []
    var headers: [HTTPHeaders] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
    func record(_ headers: HTTPHeaders) {
        lock.lock()
        captured.append(headers)
        lock.unlock()
    }
}

private final class PrivacyHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    let capture: RequestCapture
    let location: String?
    init(capture: RequestCapture, location: String?) {
        self.capture = capture
        self.location = location
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): capture.record(head.headers)
        case .end:
            var headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
            if let location { headers.add(name: "Location", value: location) }
            context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(
                version: .http1_1, status: location == nil ? .ok : .found, headers: headers))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        default: break
        }
    }
}
