import Foundation
import Network
import NetworkExtension

/// One SOCKS association per app UDP flow. No direct network fallback or FRAG support.
final class AppProxyUDPBridge {
    private let flow: NEAppProxyUDPFlow
    private let queue: DispatchQueue
    private let forwardDNS: (Data, @escaping (Data?) -> Void) -> Void
    private let count: (String) -> Void
    private let finished: () -> Void
    private let control = NWConnection(host: "127.0.0.1", port: 7897, using: .tcp)
    private var relay: NWConnection?
    private var localConnections: [String: NWConnection] = [:]
    private var closed = false
    private var timer: DispatchWorkItem?
    init(flow: NEAppProxyUDPFlow, queue: DispatchQueue,
         forwardDNS: @escaping (Data, @escaping (Data?) -> Void) -> Void,
         count: @escaping (String) -> Void, finished: @escaping () -> Void) {
        self.flow = flow; self.queue = queue; self.forwardDNS = forwardDNS
        self.count = count; self.finished = finished
    }
    func start() {
        armTimer(30)
        control.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.control.stateUpdateHandler = nil
                self.sendControl(Data([5, 1, 0])) {
                    self.readExact(2) { reply in
                        guard reply == Data([5, 0]) else { self.close(); return }
                        self.sendControl(Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])) {
                            self.readExact(4) { header in
                                guard let length = SOCKSConnect.replyAddressLength(header), length > 0 else { self.close(); return }
                                self.readExact(length) { address in
                                    let frame = Data([0, 0, 0, header[3]]) + address
                                    guard let packet = SOCKSDatagram.decode(frame),
                                          ["127.0.0.1", "0.0.0.0", "::1", "::"].contains(packet.host),
                                          let port = Network.NWEndpoint.Port(rawValue: packet.port) else { self.close(); return }
                                    self.connectRelay(port)
                                }
                            }
                        }
                    }
                }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        control.start(queue: queue)
    }
    private func connectRelay(_ port: Network.NWEndpoint.Port) {
        guard !closed else { return }
        let relay = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        self.relay = relay
        relay.stateUpdateHandler = { state in
            switch state {
            case .ready:
                relay.stateUpdateHandler = nil
                self.flow.open(withLocalEndpoint: nil) { error in
                    self.queue.async {
                        guard !self.closed, error == nil else { self.close(); return }
                        self.armTimer(180); self.count("socks_udp_connected")
                        self.readClient(); self.readRelay()
                        // An association is only valid while its TCP control stays open.
                        self.control.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in self.close() }
                    }
                }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        relay.start(queue: queue)
    }
    private func readClient() {
        guard !closed else { return }
        flow.readDatagrams { datagrams, endpoints, error in
            self.queue.async {
                guard !self.closed, error == nil, let datagrams, let endpoints,
                      datagrams.count == endpoints.count, !datagrams.isEmpty, datagrams.count <= 32, endpoints.allSatisfy({ $0 is NWHostEndpoint }) else { self.close(); return }
                self.sendBatch(datagrams, endpoints.compactMap { $0 as? NWHostEndpoint }, index: 0)
            }
        }
    }
    private func sendBatch(_ data: [Data], _ endpoints: [NWHostEndpoint], index: Int) {
        guard !closed else { return }
        guard index < data.count else { readClient(); return }
        let endpoint = endpoints[index]
        guard let port = UInt16(endpoint.port), port > 0, let relay else { close(); return }
        armTimer(180)
        if port == 53 {
            forwardDNS(data[index]) { response in
                guard !self.closed, let response else { self.close(); return }
                self.flow.writeDatagrams([response], sentBy: [endpoint]) { error in
                    self.queue.async {
                        if error != nil { self.close() } else { self.sendBatch(data, endpoints, index: index + 1) }
                    }
                }
            }
        } else if AppProbeProvider.isLoopback(endpoint.hostname) {
            let key = endpoint.hostname + ":" + endpoint.port
            let connection: NWConnection
            if let existing = localConnections[key] { connection = existing }
            else {
                guard localConnections.count < 32, let port = Network.NWEndpoint.Port(rawValue: port) else { close(); return }
                connection = NWConnection(host: Network.NWEndpoint.Host(endpoint.hostname), port: port, using: .udp)
                localConnections[key] = connection
                connection.stateUpdateHandler = { state in
                    if case .failed = state { self.close() }
                }
                connection.start(queue: queue)
                readLocal(connection, endpoint: endpoint)
            }
            connection.send(content: data[index], completion: .contentProcessed { error in
                if error != nil { self.close() } else {
                    self.count("local_udp_sent"); self.sendBatch(data, endpoints, index: index + 1)
                }
            })
        } else {
            guard let packet = SOCKSDatagram.encode(host: endpoint.hostname, port: port, payload: data[index]) else { close(); return }
            relay.send(content: packet, completion: .contentProcessed { error in
                if error != nil { self.close() } else {
                    self.count("udp_sent"); self.sendBatch(data, endpoints, index: index + 1)
                }
            })
        }
    }
    private func readLocal(_ connection: NWConnection, endpoint: NWHostEndpoint) {
        guard !closed else { return }
        connection.receiveMessage { data, _, _, error in
            guard !self.closed, error == nil, let data else { self.close(); return }
            self.armTimer(180)
            self.flow.writeDatagrams([data], sentBy: [endpoint]) { error in
                self.queue.async {
                    if error != nil { self.close() } else {
                        self.count("local_udp_received"); self.readLocal(connection, endpoint: endpoint)
                    }
                }
            }
        }
    }
    private func readRelay() {
        guard !closed, let relay else { return }
        relay.receiveMessage { data, _, _, error in
            guard !self.closed, error == nil, let data, let packet = SOCKSDatagram.decode(data) else { self.close(); return }
            self.armTimer(180)
            self.flow.writeDatagrams([packet.payload], sentBy: [NWHostEndpoint(hostname: packet.host, port: String(packet.port))]) { error in
                self.queue.async {
                    if error != nil { self.close() } else { self.count("udp_received"); self.readRelay() }
                }
            }
        }
    }
    private func armTimer(_ seconds: Double) {
        timer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        self.timer = timer; queue.asyncAfter(deadline: .now() + seconds, execute: timer)
    }
    private func sendControl(_ data: Data, _ next: @escaping () -> Void) {
        guard !closed else { return }
        control.send(content: data, completion: .contentProcessed { error in
            if error != nil { self.close() } else if !self.closed { next() }
        })
    }
    private func readExact(_ size: Int, _ next: @escaping (Data) -> Void) {
        guard !closed else { return }
        control.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, _, error in
            guard !self.closed, error == nil, let data, data.count == size else { self.close(); return }
            next(data)
        }
    }
    func close() {
        guard !closed else { return }
        closed = true; timer?.cancel(); control.cancel(); relay?.cancel()
        for connection in localConnections.values { connection.cancel() }
        localConnections.removeAll()
        let error = NSError(domain: "AppProxyUDP", code: 1)
        flow.closeReadWithError(error); flow.closeWriteWithError(error); finished()
    }
}
