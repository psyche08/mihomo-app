import Darwin
import Foundation
import MihomoDNSCore

private let defaultConfigPath = "/Library/Application Support/Mihomo App/daemon.json"
private let arguments = CommandLine.arguments
private let commandMode = arguments.contains("--check")
    || arguments.contains("--restore-system-dns")
    || arguments.contains("--check-system-dns")
    || arguments.contains("--health")

ServiceLog.configure(
    logPath: commandMode
        ? "/Library/Logs/Mihomo App/mihomo-agent-command.log"
        : "/Library/Logs/Mihomo App/mihomo-agent.log",
    crashLogPath: commandMode
        ? "/Library/Logs/Mihomo App/mihomo-agent-command-crash.log"
        : "/Library/Logs/Mihomo App/mihomo-agent-crash.log"
)
ServiceLog.installCrashSignalHandlers()
ServiceLog.info("event=agent_started pid=\(getpid())")

if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: mihomo-agent [--config PATH] [--check] [--health] [--check-system-dns] [--restore-system-dns]")
    exit(0)
}

var configPath = defaultConfigPath
if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
    configPath = arguments[index + 1]
}

do {
    let configuration = try ProxyConfiguration.load(path: configPath)
    if arguments.contains("--check") {
        ServiceLog.info("event=agent_command command=check result=success")
        print("configuration valid")
        exit(0)
    }
    if arguments.contains("--restore-system-dns") {
        ServiceLog.info("event=agent_command command=restore_system_dns phase=started")
        try ProxyService.restoreSystemDNS(configuration: configuration)
        ServiceLog.info("event=agent_command command=restore_system_dns result=success")
        print("system DNS restored")
        exit(0)
    }
    if arguments.contains("--check-system-dns") {
        guard try ProxyService.isSystemDNSApplied(configuration: configuration) else {
            ServiceLog.error("event=agent_command command=check_system_dns result=inconsistent")
            print("system DNS preferences are not applied")
            exit(1)
        }
        ServiceLog.info("event=agent_command command=check_system_dns result=success")
        print("system DNS preferences applied")
        exit(0)
    }
    if arguments.contains("--health") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ProxyService.networkHealth(configuration: configuration))
        ServiceLog.info("event=agent_command command=health result=success")
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }

    signal(SIGPIPE, SIG_IGN)
    let service = ProxyService(configuration: configuration)
    let signalQueue = DispatchQueue(label: "dev.linsheng.mihomo-app.agent.signal")
    let semaphore = DispatchSemaphore(value: 0)
    var sources: [DispatchSourceSignal] = []
    for value in [SIGTERM, SIGINT] {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: signalQueue)
        source.setEventHandler {
            ServiceLog.info("event=agent_shutdown_requested signal=\(value)")
            semaphore.signal()
        }
        source.resume()
        sources.append(source)
    }

    try service.start()
    semaphore.wait()
    ServiceLog.info("event=agent_stopping")
    service.stop()
    _ = sources
} catch {
    ServiceLog.error("event=agent_fatal error=\(String(describing: error))")
    exit(1)
}
