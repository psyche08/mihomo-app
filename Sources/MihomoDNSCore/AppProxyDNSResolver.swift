import Foundation
import MihomoControl
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// Resolves App Proxy DNS queries for the root daemon against the core's
/// fixed DNS listener (127.0.0.1:1153 by default; UDP first, TCP when the
/// answer is truncated). The listener is not on port 53, so DNS Proxy
/// providers that intercept port-53 flows do not see these queries.
///
/// The work runs on one private event loop and never takes the daemon's
/// lifecycle lock. The number of outstanding queries is bounded; a query over
/// the bound fails at once rather than queueing. Nothing about a query or its
/// answer is logged.
public final class AppProxyDNSResolver: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case invalidQuery
        case busy
        case invalidResponse
        case unavailable
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let endpoint: Endpoint
    private let timeoutMilliseconds: Int
    private let maximumInFlight: Int
    private let lock = NSLock()
    private var inFlight = 0
    private var closed = false

    public init(
        endpoint: Endpoint,
        timeoutMilliseconds: Int = AppProxyDNSPolicy.resolveTimeoutMilliseconds,
        maximumInFlight: Int = AppProxyDNSPolicy.maximumInFlight
    ) {
        self.endpoint = endpoint
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumInFlight = maximumInFlight
    }

    /// The core DNS endpoint from daemon.json, or the packaged default.
    public static func coreEndpoint(configurationPath: String) -> Endpoint {
        (try? ProxyConfiguration.load(path: configurationPath).mihomoDNS)
            ?? Endpoint(host: "127.0.0.1", port: 1153)
    }

    /// Calls `completion` exactly once, on the resolver's event loop.
    public func resolve(
        _ query: Data,
        completion: @escaping @Sendable (Result<Data, Failure>) -> Void
    ) {
        guard AppProxyDNSPolicy.isAcceptableQuery(query) else {
            completion(.failure(.invalidQuery))
            return
        }
        guard reserve() else {
            completion(.failure(.busy))
            return
        }
        let eventLoop = group.next()
        AsyncSocketDNSClient.query(
            query,
            endpoint: endpoint,
            timeoutMilliseconds: timeoutMilliseconds,
            interfaceName: nil,
            on: eventLoop
        ).whenComplete { [self] result in
            release()
            switch result {
            case .success(let response)
                where AppProxyDNSPolicy.isMatchingResponse(response, for: query):
                completion(.success(response))
            case .success:
                completion(.failure(.invalidResponse))
            case .failure:
                completion(.failure(.unavailable))
            }
        }
    }

    /// Outstanding queries, for diagnostics only.
    public var outstanding: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    public func shutdown() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        group.shutdownGracefully { _ in }
    }

    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, inFlight < maximumInFlight else { return false }
        inFlight += 1
        return true
    }

    private func release() {
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
    }
}
