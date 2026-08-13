import Foundation
import MihomoControl
import MihomoDNSCore

final class ControllerBroker: @unchecked Sendable {
    private let configPath: String
    private let streamLock = NSLock()
    private var streams: [String: ControllerStreamSession] = [:]
    private var streamOwnership = ControllerStreamOwnership()
    private let maximumStreams = 32
    private let sessionLock = NSLock()
    private var pooledSession: URLSession?
    private var pooledSessionKey: String?
    private let streamCleanupQueue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.controller-streams")
    private var streamCleanupTimer: DispatchSourceTimer?

    init(configPath: String) {
        self.configPath = configPath
        let timer = DispatchSource.makeTimerSource(queue: streamCleanupQueue)
        timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.removeExpiredStreams()
        }
        timer.resume()
        streamCleanupTimer = timer
    }

    deinit {
        pooledSession?.finishTasksAndInvalidate()
        streamCleanupTimer?.cancel()
        streamLock.lock()
        let active = Array(streams.values)
        streams.removeAll()
        streamOwnership.removeAll()
        streamLock.unlock()
        for stream in active {
            stream.close()
        }
    }

    func perform(_ request: ControlRequest, owner: ObjectIdentifier? = nil) throws -> Data {
        // Stream continuation and teardown never touch the controller endpoint,
        // so they must not pay for reading and validating the daemon config.
        // With a dashboard open `next` runs several times a second, and this
        // was a disk read plus a JSON decode each time, inside the root daemon.
        switch request.operation {
        case .controllerStreamNext:
            guard let identifier = request.arguments["session"] else {
                throw brokerError("controller stream session is required")
            }
            return try nextStreamMessage(identifier: identifier, owner: owner)
        case .controllerStreamClose:
            guard let identifier = request.arguments["session"] else {
                throw brokerError("controller stream session is required")
            }
            try closeStream(identifier: identifier, owner: owner)
            return Data()
        default:
            break
        }
        let configuration = try ProxyConfiguration.load(path: configPath)
        switch request.operation {
        case .snapshot:
            let configs = try send(configuration, method: "GET", path: "/configs")
            let proxies = try send(configuration, method: "GET", path: "/proxies")
            let object: [String: Any] = [
                "configs": try JSONSerialization.jsonObject(with: configs),
                "proxies": try JSONSerialization.jsonObject(with: proxies),
            ]
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        case .setTUN:
            guard let value = request.arguments["enabled"], value == "true" || value == "false" else {
                throw brokerError("invalid Enhanced TUN state")
            }
            let enabled = value == "true"
            return try sendJSON(
                configuration,
                method: "PATCH",
                path: "/configs",
                object: ["tun": ["enable": enabled]]
            )
        case .setOutboundMode:
            guard let mode = request.arguments["mode"], ["rule", "global", "direct"].contains(mode) else {
                throw brokerError("invalid outbound mode")
            }
            return try sendJSON(
                configuration,
                method: "PATCH",
                path: "/configs",
                object: ["mode": mode]
            )
        case .selectProxy:
            guard let group = request.arguments["group"], let proxy = request.arguments["proxy"],
                  validControllerName(group), validControllerName(proxy) else {
                throw brokerError("proxy group and node are required")
            }
            return try sendJSON(
                configuration,
                method: "PUT",
                path: "/proxies/\(pathComponent(group))",
                object: ["name": proxy]
            )
        case .testDelay:
            guard let payload = request.payload, payload.count <= 1_048_576,
                  let names = try JSONSerialization.jsonObject(with: payload) as? [String],
                  names.allSatisfy(validControllerName) else {
                throw brokerError("proxy node list is required")
            }
            var succeeded = 0
            for name in names.prefix(512) {
                let encoded = pathComponent(name)
                let probe = "https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204"
                if (try? send(
                    configuration,
                    method: "GET",
                    path: "/proxies/\(encoded)/delay?timeout=5000&url=\(probe)"
                )) != nil {
                    succeeded += 1
                }
            }
            return try JSONSerialization.data(withJSONObject: ["succeeded": succeeded])
        case .controllerVersion:
            return try send(configuration, method: "GET", path: "/version")
        case .listRules:
            return try send(configuration, method: "GET", path: "/rules")
        case .listProxyProviders:
            return try send(configuration, method: "GET", path: "/providers/proxies")
        case .listRuleProviders:
            return try send(configuration, method: "GET", path: "/providers/rules")
        case .listConnections:
            return try send(configuration, method: "GET", path: "/connections")
        case .closeAllConnections:
            return try send(configuration, method: "DELETE", path: "/connections")
        case .controllerRequest:
            guard let method = request.arguments["method"],
                  let target = request.arguments["target"] else {
                throw brokerError("controller method and target are required")
            }
            try validateControllerRequest(method: method, target: target, body: request.payload)
            return try send(
                configuration,
                method: method,
                path: target,
                body: request.payload
            )
        case .controllerStreamMessage:
            guard let target = request.arguments["target"] else {
                throw brokerError("controller stream target is required")
            }
            let stream = try makeStream(configuration, target: target)
            defer { stream.close() }
            return try stream.receive()
        case .controllerStreamOpen:
            guard let target = request.arguments["target"] else {
                throw brokerError("controller stream target is required")
            }
            return try openStream(configuration, target: target, owner: owner)
        default:
            throw brokerError("operation is not a controller operation")
        }
    }

    private func sendJSON(
        _ configuration: ProxyConfiguration,
        method: String,
        path: String,
        object: Any
    ) throws -> Data {
        try send(
            configuration,
            method: method,
            path: path,
            body: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func send(
        _ configuration: ProxyConfiguration,
        method: String,
        path: String,
        body: Data? = nil
    ) throws -> Data {
        let endpoint = configuration.controllerEndpoint ?? Endpoint(host: "127.0.0.1", port: 9090)
        guard endpoint.host == "127.0.0.1",
              let url = URL(string: "http://\(endpoint.host):\(endpoint.port)\(path)") else {
            throw brokerError("invalid controller endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 8
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let secret = configuration.controllerSecret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        let session = pooledSession(for: endpoint)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode) else {
                result = .failure(self.brokerError("controller rejected the operation"))
                return
            }
            result = .success(data ?? Data())
        }.resume()
        guard semaphore.wait(timeout: .now() + .seconds(10)) == .success else {
            // Drop the pooled session: a timed-out request leaves it in an
            // unknown state, and the next call should start clean.
            discardPooledSession()
            throw brokerError("controller request timed out")
        }
        return try result?.get() ?? { throw brokerError("controller request failed") }()
    }

    /// A retained URLSession per controller endpoint.
    ///
    /// Creating an ephemeral session per request cost ~7 ms against a ~1.1 ms
    /// loopback round trip — the session setup was six times the work it was
    /// wrapping, on every controller call, twice per tray poll and once per
    /// node in a latency test.
    ///
    /// Keyed on the endpoint because a profile switch can move the controller,
    /// and rebuilt when it does. A restarted Mihomo closes the connection
    /// underneath the pool; URLSession's own retry covers that.
    private func pooledSession(for endpoint: Endpoint) -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let key = "\(endpoint.host):\(endpoint.port)"
        if let pooledSession, pooledSessionKey == key {
            return pooledSession
        }
        pooledSession?.finishTasksAndInvalidate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: configuration)
        pooledSession = session
        pooledSessionKey = key
        return session
    }

    private func discardPooledSession() {
        sessionLock.lock()
        let session = pooledSession
        pooledSession = nil
        pooledSessionKey = nil
        sessionLock.unlock()
        session?.invalidateAndCancel()
    }

    private func makeStream(
        _ configuration: ProxyConfiguration,
        target: String
    ) throws -> ControllerStreamSession {
        guard target.utf8.count <= 4_096,
              var incoming = URLComponents(string: target),
              incoming.scheme == nil, incoming.host == nil, incoming.fragment == nil,
              ["/connections", "/traffic", "/memory", "/logs"].contains(incoming.path) else {
            throw brokerError("unsupported controller stream")
        }
        let allowedQueryNames: Set<String> = incoming.path == "/logs" ? ["level"] : []
        let preserved = (incoming.queryItems ?? []).filter { allowedQueryNames.contains($0.name) }
        let endpoint = configuration.controllerEndpoint ?? Endpoint(host: "127.0.0.1", port: 9090)
        guard endpoint.host == "127.0.0.1" else {
            throw brokerError("invalid controller endpoint")
        }
        incoming.scheme = "ws"
        incoming.host = endpoint.host
        incoming.port = endpoint.port
        incoming.queryItems = preserved
        if let secret = configuration.controllerSecret, !secret.isEmpty {
            incoming.queryItems?.append(URLQueryItem(name: "token", value: secret))
        }
        guard let url = incoming.url else {
            throw brokerError("invalid controller stream URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 35
        if let secret = configuration.controllerSecret, !secret.isEmpty {
            urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return ControllerStreamSession(
            request: urlRequest,
            errorFactory: brokerError
        )
    }

    private func openStream(
        _ configuration: ProxyConfiguration,
        target: String,
        owner: ObjectIdentifier?
    ) throws -> Data {
        let stream = try makeStream(configuration, target: target)
        streamLock.lock()
        removeExpiredStreamsLocked()
        guard streams.count < maximumStreams else {
            streamLock.unlock()
            stream.close()
            throw brokerError("controller stream limit reached")
        }
        guard streamOwnership.register(identifier: stream.identifier, owner: owner) else {
            streamLock.unlock()
            stream.close()
            throw brokerError("controller stream session is unavailable")
        }
        streams[stream.identifier] = stream
        streamLock.unlock()
        ServiceLog.info("event=controller_stream result=opened")
        return try JSONSerialization.data(
            withJSONObject: ["session": stream.identifier],
            options: [.sortedKeys]
        )
    }

    private func nextStreamMessage(identifier: String, owner: ObjectIdentifier?) throws -> Data {
        guard UUID(uuidString: identifier) != nil else {
            throw brokerError("invalid controller stream session")
        }
        streamLock.lock()
        removeExpiredStreamsLocked()
        let stream = streamOwnership.allows(identifier: identifier, owner: owner)
            ? streams[identifier] : nil
        streamLock.unlock()
        guard let stream else {
            throw brokerError("controller stream session is unavailable")
        }
        do {
            return try stream.receive()
        } catch {
            closeStreamUnconditionally(identifier: identifier)
            throw error
        }
    }

    private func closeStream(identifier: String, owner: ObjectIdentifier?) throws {
        guard UUID(uuidString: identifier) != nil else {
            throw brokerError("invalid controller stream session")
        }
        streamLock.lock()
        removeExpiredStreamsLocked()
        guard streams[identifier] != nil,
              streamOwnership.remove(identifier: identifier, owner: owner) else {
            streamLock.unlock()
            throw brokerError("controller stream session is unavailable")
        }
        let stream = streams.removeValue(forKey: identifier)
        streamLock.unlock()
        stream?.close()
        ServiceLog.info("event=controller_stream result=closed")
    }

    /// Daemon-side cleanup must not depend on a live caller. Receive failures,
    /// expiry and peer teardown are authoritative reasons to reclaim a stream.
    private func closeStreamUnconditionally(identifier: String) {
        streamLock.lock()
        let stream = streams.removeValue(forKey: identifier)
        streamOwnership.remove(identifier: identifier)
        streamLock.unlock()
        if let stream {
            stream.close()
            ServiceLog.info("event=controller_stream result=closed")
        }
    }

    /// Caller must hold `streamLock`.
    ///
    /// This reclaims far more streams than the timer does: with a dashboard
    /// open it runs several times a second, so an idle stream is collected
    /// almost the moment it expires and the timer never sees it. It used to do
    /// that without logging, while its twin `removeExpiredStreams()` logged —
    /// which is why the logs appeared to show streams opened and never closed.
    private func removeExpiredStreamsLocked() {
        let expired = streams.filter { $0.value.isExpired }.map(\.key)
        guard !expired.isEmpty else { return }
        for identifier in expired {
            streams.removeValue(forKey: identifier)?.close()
            streamOwnership.remove(identifier: identifier)
        }
        ServiceLog.info("event=controller_stream result=expired count=\(expired.count)")
    }

    /// Releases every stream opened by a control peer that has gone away.
    ///
    /// A websocket is normally torn down by SIGKILLing the CLI that owns it, so
    /// no close request is ever sent and the stream would otherwise sit in the
    /// table until its 60s idle expiry — holding a slot in `maximumStreams`.
    /// Opening a dashboard costs four streams, so a user cycling the window a
    /// few times could exhaust the budget and be told the limit was reached.
    func releaseStreams(owner: ObjectIdentifier) {
        streamLock.lock()
        let identifiers = streamOwnership.removeAll(ownedBy: owner)
        let released = identifiers.compactMap { identifier -> ControllerStreamSession? in
            streams.removeValue(forKey: identifier)
        }
        streamLock.unlock()
        for stream in released {
            stream.close()
        }
        if !released.isEmpty {
            ServiceLog.info("event=controller_stream result=peer_released count=\(released.count)")
        }
    }

    private func removeExpiredStreams() {
        streamLock.lock()
        let expired = streams.filter { $0.value.isExpired }.map(\.key)
        let removed = expired.compactMap { identifier -> ControllerStreamSession? in
            streamOwnership.remove(identifier: identifier)
            return streams.removeValue(forKey: identifier)
        }
        streamLock.unlock()
        for stream in removed {
            stream.close()
        }
        if !removed.isEmpty {
            ServiceLog.info("event=controller_stream result=expired count=\(removed.count)")
        }
    }

    private func validateControllerRequest(method: String, target: String, body: Data?) throws {
        guard ["GET", "PUT", "PATCH", "POST", "DELETE"].contains(method),
              ControllerRequestPolicy.allows(method: method, target: target, body: body) else {
            throw brokerError("invalid controller request")
        }
    }

    private func brokerError(_ message: String) -> Error {
        NSError(domain: "MihomoController", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func validControllerName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private final class ControllerStreamSession: @unchecked Sendable {
    private static let maximumFrameBytes = 16 * 1_024 * 1_024

    let identifier = UUID().uuidString
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let errorFactory: (String) -> Error
    private let receiveLock = NSLock()
    private let stateLock = NSLock()
    private var lastAccessNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var closed = false

    init(request: URLRequest, errorFactory: @escaping (String) -> Error) {
        self.errorFactory = errorFactory
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumFrameBytes
        task.resume()
    }

    var isExpired: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
            || DispatchTime.now().uptimeNanoseconds &- lastAccessNanoseconds
                > 60_000_000_000
    }

    func receive() throws -> Data {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        touch()
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        task.receive { [errorFactory] message in
            defer { semaphore.signal() }
            switch message {
            case let .success(.string(value)):
                result = .success(Data(value.utf8))
            case let .success(.data(value)):
                result = .success(value)
            case let .failure(error):
                result = .failure(error)
            @unknown default:
                result = .failure(errorFactory("unsupported controller stream message"))
            }
        }
        guard semaphore.wait(timeout: .now() + .seconds(36)) == .success else {
            throw errorFactory("controller stream timed out")
        }
        touch()
        let frame = try result?.get() ?? { throw errorFactory("controller stream failed") }()
        guard frame.count <= Self.maximumFrameBytes else {
            close()
            throw errorFactory("controller stream frame exceeds the size limit")
        }
        return frame
    }

    func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func touch() {
        stateLock.lock()
        lastAccessNanoseconds = DispatchTime.now().uptimeNanoseconds
        stateLock.unlock()
    }
}
