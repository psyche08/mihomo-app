import Foundation
import MihomoControl
import MihomoDNSCore

final class ControllerBroker: @unchecked Sendable {
    private let configPath: String

    init(configPath: String) {
        self.configPath = configPath
    }

    func perform(_ request: ControlRequest) throws -> Data {
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
            return try receiveStreamMessage(configuration, target: target)
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
        let session = URLSession(configuration: .ephemeral)
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
            session.invalidateAndCancel()
            throw brokerError("controller request timed out")
        }
        session.finishTasksAndInvalidate()
        return try result?.get() ?? { throw brokerError("controller request failed") }()
    }

    private func receiveStreamMessage(
        _ configuration: ProxyConfiguration,
        target: String
    ) throws -> Data {
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
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: urlRequest)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        task.resume()
        task.receive { message in
            defer { semaphore.signal() }
            switch message {
            case let .success(.string(value)):
                result = .success(Data(value.utf8))
            case let .success(.data(value)):
                result = .success(value)
            case let .failure(error):
                result = .failure(error)
            @unknown default:
                result = .failure(self.brokerError("unsupported controller stream message"))
            }
        }
        guard semaphore.wait(timeout: .now() + .seconds(36)) == .success else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw brokerError("controller stream timed out")
        }
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
        return try result?.get() ?? { throw brokerError("controller stream failed") }()
    }

    private func validateControllerRequest(method: String, target: String, body: Data?) throws {
        guard ["GET", "PUT", "PATCH", "POST", "DELETE"].contains(method),
              target.utf8.count <= 4_096,
              let components = URLComponents(string: target),
              components.scheme == nil, components.host == nil, components.fragment == nil,
              components.path.hasPrefix("/"), !components.path.contains(".."),
              (body?.count ?? 0) <= 1_048_576 else {
            throw brokerError("invalid controller request")
        }

        let path = components.path
        let exact: Set<String> = [
            "GET /version", "GET /configs", "GET /proxies", "GET /rules",
            "GET /providers/proxies", "GET /providers/rules", "GET /connections",
            "DELETE /connections", "PATCH /configs", "PUT /configs", "PATCH /rules/disable",
            "POST /cache/fakeip/flush", "POST /cache/dns/flush", "POST /configs/geo",
        ]
        let signature = "\(method) \(path)"
        var allowed = exact.contains(signature)
        allowed = allowed || route(method, path, prefix: "/proxies/", segmentCounts: [1], suffix: nil)
        allowed = allowed || route(method, path, prefix: "/proxies/", segmentCounts: [1], suffix: "/delay")
        allowed = allowed || route(method, path, prefix: "/group/", segmentCounts: [1], suffix: "/delay")
        allowed = allowed || route(method, path, prefix: "/providers/proxies/", segmentCounts: [1], suffix: nil)
        allowed = allowed || route(method, path, prefix: "/providers/proxies/", segmentCounts: [1, 2], suffix: "/healthcheck")
        allowed = allowed || route(method, path, prefix: "/providers/rules/", segmentCounts: [1], suffix: nil)
        allowed = allowed || route(method, path, prefix: "/connections/", segmentCounts: [1], suffix: nil)
        guard allowed else {
            throw brokerError("unsupported controller operation")
        }

        if method == "PATCH", path == "/configs" {
            try validateConfigPatch(body)
        }
        if method == "PUT", path == "/configs" {
            try validateInlineConfig(body)
        }
        if method == "PUT", path.hasPrefix("/proxies/"), !path.hasSuffix("/delay") {
            guard let body, body.count > 0 else { throw brokerError("proxy selection body is required") }
        }
    }

    private func route(
        _ method: String,
        _ path: String,
        prefix: String,
        segmentCounts: Set<Int>,
        suffix: String?
    ) -> Bool {
        let methods: Set<String>
        if prefix == "/proxies/" && suffix == nil { methods = ["PUT", "DELETE"] }
        else if prefix == "/connections/" { methods = ["DELETE"] }
        else if suffix == "/delay" || suffix == "/healthcheck" { methods = ["GET"] }
        else { methods = ["PUT"] }
        guard methods.contains(method), path.hasPrefix(prefix) else { return false }
        var middle = String(path.dropFirst(prefix.count))
        if let suffix {
            guard middle.hasSuffix(suffix) else { return false }
            middle.removeLast(suffix.count)
        }
        let segments = middle.split(separator: "/", omittingEmptySubsequences: false)
        return segmentCounts.contains(segments.count) && segments.allSatisfy { !$0.isEmpty }
    }

    private func validateConfigPatch(_ body: Data?) throws {
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw brokerError("config patch must be a JSON object")
        }
        let protected = Set([
            "external-controller", "external-controller-tls", "secret", "external-ui",
            "external-ui-url", "external-ui-name", "authentication", "skip-auth-prefixes",
        ])
        guard protected.isDisjoint(with: object.keys) else {
            throw brokerError("controller identity fields are managed by MihomoBox")
        }
        if let dns = object["dns"] as? [String: Any] {
            let managedDNS = Set([
                "listen", "respect-rules", "nameserver", "direct-nameserver",
                "proxy-server-nameserver",
            ])
            guard managedDNS.isDisjoint(with: dns.keys) else {
                throw brokerError("DNS recursion-boundary fields are managed by MihomoBox")
            }
        }
    }

    private func validateInlineConfig(_ body: Data?) throws {
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let payload = object["payload"] as? String, !payload.isEmpty,
              (object["path"] as? String ?? "").isEmpty,
              Set(object.keys).isSubset(of: ["path", "payload"]) else {
            throw brokerError("inline config reload requires a payload and an empty path")
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
