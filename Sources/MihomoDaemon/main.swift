import Darwin
import Foundation
import MihomoDNSCore

private let root = URL(fileURLWithPath: "/Library/Application Support/Mihomo App", isDirectory: true)
private let defaultConfigPath = root.appendingPathComponent("daemon.json").path
private let arguments = CommandLine.arguments
private let startupClock = MonotonicStartupClock()

ServiceLog.configure(
    logPath: "/Library/Logs/Mihomo App/mihomo-daemon.log",
    crashLogPath: "/Library/Logs/Mihomo App/mihomo-daemon-crash.log"
)
ServiceLog.installCrashSignalHandlers()
ServiceLog.info("event=daemon_started pid=\(getpid())")
ServiceLog.info(
    "event=daemon_startup phase=process_started elapsed_ms=\(startupClock.elapsedMilliseconds())"
)

if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: mihomo-daemon [--config PATH]")
    exit(0)
}

var configPath = defaultConfigPath
if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
    configPath = arguments[index + 1]
}

do {
    signal(SIGPIPE, SIG_IGN)
    let agent = AgentSupervisor(configPath: configPath)
    defer {
        if !agent.stopAndRestoreVerified() {
            ServiceLog.error("event=daemon_shutdown result=restore_unconfirmed")
        }
    }
    let dispatcher = try ControlDispatcher(
        agent: agent,
        configPath: configPath,
        startupClock: startupClock
    )
    let server = try ControlServer(dispatcher: dispatcher)

    let signalQueue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.signal")
    let stopped = DispatchSemaphore(value: 0)
    var sources: [DispatchSourceSignal] = []
    for value in [SIGTERM, SIGINT] {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: signalQueue)
        source.setEventHandler {
            ServiceLog.info("event=daemon_shutdown_requested signal=\(value)")
            stopped.signal()
        }
        source.resume()
        sources.append(source)
    }

    try server.start()
    ServiceLog.info(
        "event=daemon_startup phase=control_ready elapsed_ms=\(startupClock.elapsedMilliseconds())"
    )
    dispatcher.startInitialRuntime()
    stopped.wait()
    server.stop()
    ServiceLog.info("event=daemon_stopping")
    _ = sources
} catch {
    ServiceLog.error("event=daemon_fatal error=control_service_unavailable")
    exit(1)
}
