import Foundation
import Network

/// Keeps NetworkExtension's C interface identity intact. Reconstructing an
/// unscoped Swift NWConnection inside a provider selects its default physical
/// path and can lose the caller's bridge or private VPN route.
final class AppProxyConnection {
    enum Transport { case tcp, udp }
    enum State { case ready, failed, cancelled }
    enum Context { case finalMessage }
    enum Completion { case contentProcessed((Error?) -> Void) }
    private let connection: nw_connection_t
    var stateUpdateHandler: ((State) -> Void)?

    static func parameters(_ transport: Transport, interface: nw_interface_t?) -> nw_parameters_t {
        let parameters = nw_parameters_create()
        let stack = nw_parameters_copy_default_protocol_stack(parameters)
        nw_protocol_stack_set_transport_protocol(stack, transport == .tcp ? nw_tcp_create_options() : nw_udp_create_options())
        if let interface { nw_parameters_require_interface(parameters, interface) }
        return parameters
    }
    init(host: String, port: UInt16, transport: Transport, interface: nw_interface_t? = nil) {
        connection = nw_connection_create(nw_endpoint_create_host(host, String(port)),
                                          Self.parameters(transport, interface: interface))
    }
    func start(queue: DispatchQueue) {
        nw_connection_set_queue(connection, queue)
        nw_connection_set_state_changed_handler(connection) { [weak self] state, _ in
            switch state {
            case nw_connection_state_ready: self?.stateUpdateHandler?(.ready)
            case nw_connection_state_failed: self?.stateUpdateHandler?(.failed)
            case nw_connection_state_cancelled: self?.stateUpdateHandler?(.cancelled)
            default: break
            }
        }
        nw_connection_start(connection)
    }
    func cancel() {
        stateUpdateHandler = nil
        nw_connection_cancel(connection)
    }
    func send(content: Data?, contentContext: Context? = nil, isComplete: Bool = true, completion: Completion) {
        let bytes = content.map { data in data.withUnsafeBytes { DispatchData(bytes: $0) as dispatch_data_t } }
        let context = contentContext == nil ? _nw_content_context_default_message : _nw_content_context_final_send
        nw_connection_send(connection, bytes, context, isComplete) { error in
            if case let .contentProcessed(done) = completion { done(Self.error(error)) }
        }
    }
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Void?, Bool, Error?) -> Void) {
        nw_connection_receive(connection, UInt32(minimumIncompleteLength), UInt32(maximumLength)) { bytes, _, complete, error in
            completion(Self.data(bytes), nil, complete, Self.error(error))
        }
    }
    func receiveMessage(completion: @escaping (Data?, Void?, Bool, Error?) -> Void) {
        nw_connection_receive_message(connection) { bytes, _, complete, error in
            completion(Self.data(bytes), nil, complete, Self.error(error))
        }
    }
    private static func data(_ bytes: dispatch_data_t?) -> Data? {
        guard let bytes else { return nil }
        let bufferData = bytes as DispatchData
        var data = Data(); data.reserveCapacity(bufferData.count)
        bufferData.enumerateBytes { buffer, _, _ in data.append(buffer) }
        return data
    }
    private static func error(_ error: nw_error_t?) -> Error? {
        error.map { NSError(domain: "AppProxy.Network", code: Int(nw_error_get_error_code($0))) }
    }
}
