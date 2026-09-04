import CMihomoDNSSystem
import Darwin
import Foundation

struct RouteTableEvent: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let route = Self(rawValue: UInt32(MIHOMO_DNS_ROUTE_EVENT_ROUTE))
    static let address = Self(rawValue: UInt32(MIHOMO_DNS_ROUTE_EVENT_ADDRESS))
    static let interface = Self(rawValue: UInt32(MIHOMO_DNS_ROUTE_EVENT_INTERFACE))
}

enum RouteTableMonitorError: Error, Equatable {
    case openFailed(Int32)
}

/// Watches Darwin's routing socket. Messages are deliberately reduced to a
/// fixed category mask: the daemon only needs an invalidation signal and must
/// not log route destinations, gateways or interface addresses.
final class RouteTableMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.route-monitor")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let handler: @Sendable (RouteTableEvent) -> Void
    private var source: DispatchSourceRead?
    private var pendingEvent: RouteTableEvent = []
    private var pendingDelivery: DispatchWorkItem?
    private var reopenDelaySeconds = 1
    private var running = false

    init(handler: @escaping @Sendable (RouteTableEvent) -> Void) {
        self.handler = handler
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() throws {
        try onQueue {
            guard !running else { return }
            running = true
            do {
                try openSource()
            } catch {
                scheduleReopen()
                throw error
            }
        }
    }

    func stop() {
        onQueue {
            running = false
            pendingDelivery?.cancel()
            pendingDelivery = nil
            pendingEvent = []
            source?.cancel()
            source = nil
        }
    }

    private func openSource() throws {
        let descriptor = mihomo_dns_route_monitor_open()
        guard descriptor >= 0 else {
            throw RouteTableMonitorError.openFailed(Int32(-descriptor))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            var rawMask: UInt32 = 0
            let result = mihomo_dns_route_monitor_drain(descriptor, &rawMask)
            if result < 0 {
                ServiceLog.error("event=route_monitor_failed code=\(-result)")
                source.cancel()
                self.source = nil
                self.scheduleReopen()
                return
            }
            let event = RouteTableEvent(rawValue: rawMask)
            guard !event.isEmpty else { return }
            self.enqueue(event)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        reopenDelaySeconds = 1
        source.resume()
    }

    private func scheduleReopen() {
        guard running else { return }
        let delay = reopenDelaySeconds
        reopenDelaySeconds = min(reopenDelaySeconds * 2, 30)
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self, self.running, self.source == nil else { return }
            do {
                try self.openSource()
                ServiceLog.info("event=route_monitor_recovered")
            } catch let RouteTableMonitorError.openFailed(code) {
                ServiceLog.error("event=route_monitor_reopen_failed code=\(code)")
                self.scheduleReopen()
            } catch {
                ServiceLog.error("event=route_monitor_reopen_failed code=unknown")
                self.scheduleReopen()
            }
        }
    }

    private func enqueue(_ event: RouteTableEvent) {
        pendingEvent.formUnion(event)
        guard pendingDelivery == nil else { return }
        let delivery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDelivery = nil
            let event = self.pendingEvent
            self.pendingEvent = []
            guard self.running, !event.isEmpty else { return }
            self.handler(event)
        }
        pendingDelivery = delivery
        // Route changes commonly arrive as route + address + interface bursts.
        // Collapse the burst before invalidating probes or reading SC state.
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: delivery)
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}
