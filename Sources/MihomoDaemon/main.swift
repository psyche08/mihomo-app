import Darwin
import Foundation
import MihomoDNSCore

private let root = URL(fileURLWithPath: "/Library/Application Support/Mihomo App", isDirectory: true)
private let defaultConfigPath = root.appendingPathComponent("daemon.json").path
private let arguments = CommandLine.arguments

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
    defer { agent.stop() }
    let dispatcher = ControlDispatcher(agent: agent, configPath: configPath)
    let server = try ControlServer(dispatcher: dispatcher)

    let signalQueue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.signal")
    let stopped = DispatchSemaphore(value: 0)
    var sources: [DispatchSourceSignal] = []
    for value in [SIGTERM, SIGINT] {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: signalQueue)
        source.setEventHandler { stopped.signal() }
        source.resume()
        sources.append(source)
    }

    try agent.start()
    try server.start()
    stopped.wait()
    server.stop()
    ServiceLog.info("event=daemon_stopping")
    _ = sources
} catch {
    ServiceLog.error("event=daemon_fatal error=control_service_unavailable")
    exit(1)
}
