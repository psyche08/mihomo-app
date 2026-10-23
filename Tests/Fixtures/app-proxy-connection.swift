import Foundation
import Network

let queue = DispatchQueue(label: "app-proxy-route-transport-test")
let pathReady = DispatchSemaphore(value: 0)
let monitor = nw_path_monitor_create_with_type(nw_interface_type_loopback)
var loopback: nw_interface_t?
nw_path_monitor_set_queue(monitor, queue)
nw_path_monitor_set_update_handler(monitor) { path in
    nw_path_enumerate_interfaces(path) { interface in
        if nw_interface_get_type(interface) == nw_interface_type_loopback { loopback = interface }
        return true
    }
    pathReady.signal()
}
nw_path_monitor_start(monitor)
precondition(pathReady.wait(timeout: .now() + 3) == .success)
guard let loopback else { fatalError("missing loopback interface") }
nw_path_monitor_cancel(monitor)
for transport in [AppProxyConnection.Transport.tcp, .udp] {
    let parameters = AppProxyConnection.parameters(transport, interface: loopback)
    let actual = nw_parameters_copy_required_interface(parameters)!
    precondition(nw_interface_get_index(actual) == nw_interface_get_index(loopback))
    precondition(nw_parameters_copy_required_interface(AppProxyConnection.parameters(transport, interface: nil)) == nil)
}

func tcp(interface: nw_interface_t?) throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    let halfClosed = DispatchSemaphore(value: 0)
    let payload = Data((0..<65536).map { UInt8($0 % 251) })
    var peers: [NWConnection] = []
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { peer in
        peers.append(peer); peer.start(queue: queue)
        peer.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) { data, _, _, error in
            precondition(error == nil && data == payload)
            peer.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                precondition(complete && error == nil); halfClosed.signal()
                peer.send(content: payload.prefix(17), completion: .contentProcessed { error in
                    precondition(error == nil)
                    peer.send(content: payload.dropFirst(17), contentContext: .finalMessage,
                              isComplete: true, completion: .contentProcessed { precondition($0 == nil) })
                })
            }
        }
    }
    listener.start(queue: queue)
    precondition(ready.wait(timeout: .now() + 3) == .success)
    let client = AppProxyConnection(host: "127.0.0.1", port: listener.port!.rawValue, transport: .tcp, interface: interface)
    var received = Data()
    func read() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, complete, error in
            precondition(error == nil)
            if let data { received.append(data) }
            if complete { precondition(received == payload); done.signal() } else { read() }
        }
    }
    client.stateUpdateHandler = { state in
        guard case .ready = state else { fatalError("TCP setup failed") }
        client.stateUpdateHandler = nil
        client.send(content: payload, completion: .contentProcessed { error in
            precondition(error == nil)
            client.send(content: nil, contentContext: .finalMessage, completion: .contentProcessed { precondition($0 == nil) })
        })
        read()
    }
    client.start(queue: queue)
    precondition(done.wait(timeout: .now() + 5) == .success)
    precondition(halfClosed.wait(timeout: .now() + 1) == .success)
    queue.sync { client.cancel(); client.cancel(); peers.forEach { $0.cancel() }; listener.cancel() }
}
func udp() throws {
    let listener = try NWListener(using: .udp, on: .any)
    let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    let payload = Data(repeating: 0xa5, count: 4096)
    var peers: [NWConnection] = []
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { peer in
        peers.append(peer); peer.start(queue: queue)
        peer.receiveMessage { data, _, _, error in
            precondition(error == nil && data == payload)
            peer.send(content: data, completion: .contentProcessed { precondition($0 == nil) })
        }
    }
    listener.start(queue: queue)
    precondition(ready.wait(timeout: .now() + 3) == .success)
    let client = AppProxyConnection(host: "127.0.0.1", port: listener.port!.rawValue, transport: .udp, interface: loopback)
    client.stateUpdateHandler = { state in
        guard case .ready = state else { fatalError("UDP setup failed") }
        client.stateUpdateHandler = nil
        client.receiveMessage { data, _, _, error in
            precondition(error == nil && data == payload); done.signal()
        }
        client.send(content: payload, completion: .contentProcessed { precondition($0 == nil) })
    }
    client.start(queue: queue)
    precondition(done.wait(timeout: .now() + 5) == .success)
    queue.sync { client.cancel(); peers.forEach { $0.cancel() }; listener.cancel() }
}
try tcp(interface: loopback); try tcp(interface: nil); try udp()
print("App Proxy transport: interface binding, fragmented TCP, half-close, UDP and cancellation passed")
