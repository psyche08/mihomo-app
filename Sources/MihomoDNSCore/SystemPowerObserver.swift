import Foundation
import IOKit
import IOKit.pwr_mgt

/// Observes system sleep and wake.
///
/// The agent runs as a root LaunchDaemon with no GUI session, so `NSWorkspace`
/// wake notifications are not delivered to it; the IOKit power-management
/// notification port is the mechanism that works in that context.
///
/// This matters because the runtime observer is otherwise purely a poller: after
/// a wake, the kernel's TUN interface, the default route and the outbound
/// interface binding can all have changed while every locally-answered health
/// signal still reads healthy. A wake is the single highest-yield moment to
/// force a full revalidation.
/// Power-management message types.
///
/// `IOPMLib.h` defines these via the `iokit_common_msg()` macro, which Swift
/// cannot import ("macro unavailable: structure not supported"), so the expanded
/// values are spelled out here. `iokit_common_msg(x)` is
/// `sys_iokit | sub_iokit_common | x`, where `sys_iokit` is `err_system(0x38)`
/// = `(0x38 & 0x3f) << 26` = `0xE000_0000` and `sub_iokit_common` is 0.
enum SystemPowerMessage {
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
}

public final class SystemPowerObserver: @unchecked Sendable {
    private let onSleep: @Sendable () -> Void
    private let onWake: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.power")
    private let lock = NSLock()
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    public init(
        onSleep: @escaping @Sendable () -> Void = {},
        onWake: @escaping @Sendable () -> Void
    ) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard rootPort == 0 else { return }

        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<SystemPowerObserver>.fromOpaque(refcon)
                .takeUnretainedValue()
                .handle(messageType: messageType, argument: messageArgument)
        }

        var port: IONotificationPortRef?
        var object: io_object_t = 0
        let connection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            callback,
            &object
        )
        guard connection != 0, let port else {
            ServiceLog.error("event=power_observer_unavailable")
            return
        }
        IONotificationPortSetDispatchQueue(port, queue)
        rootPort = connection
        notificationPort = port
        notifier = object
        ServiceLog.info("event=power_observer_started")
    }

    public func stop() {
        lock.lock()
        let connection = rootPort
        let port = notificationPort
        let object = notifier
        rootPort = 0
        notificationPort = nil
        notifier = 0
        lock.unlock()

        guard connection != 0 else { return }
        var deregistered = object
        if deregistered != 0 {
            IODeregisterForSystemPower(&deregistered)
        }
        IOServiceClose(connection)
        if let port {
            IONotificationPortDestroy(port)
        }
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        lock.lock()
        let connection = rootPort
        lock.unlock()
        guard connection != 0 else { return }
        let token = Int(bitPattern: argument)

        switch messageType {
        case SystemPowerMessage.canSystemSleep:
            // Never veto an idle-sleep request; failing to answer stalls sleep
            // for 30 seconds.
            IOAllowPowerChange(connection, token)
        case SystemPowerMessage.systemWillSleep:
            onSleep()
            // Must acknowledge, otherwise the system waits out the timeout
            // before sleeping.
            IOAllowPowerChange(connection, token)
        case SystemPowerMessage.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
