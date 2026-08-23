import Darwin
import Foundation
import MihomoDNSCore

/// stderr as a TextOutputStream, so command failures report on the right
/// stream rather than being mixed into stdout.
struct StandardError: TextOutputStream {
    func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

var standardError = StandardError()

private let defaultConfigPath = "/Library/Application Support/Mihomo App/daemon.json"
private let arguments = CommandLine.arguments
private let startupClock = MonotonicStartupClock()
private let commandMode = arguments.contains("--check")
    || arguments.contains("--restore-system-dns")
    || arguments.contains("--check-system-dns")
    || arguments.contains("--check-system-dns-restored")
    || arguments.contains("--health")
    || arguments.contains("--configure-profile")
    || arguments.contains("--restore-profile")

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
if !commandMode {
    ServiceLog.info(
        "event=agent_startup phase=process_started elapsed_ms=\(startupClock.elapsedMilliseconds())"
    )
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    usage: mihomo-agent [--config PATH] [--check] [--health]
                        [--check-system-dns] [--check-system-dns-restored]
                        [--restore-system-dns]
                        [--configure-profile --profile PATH --profile-backup PATH
                         [--secret-file PATH] [--controller-metadata PATH]
                         [--daemon-config PATH]]
                        [--restore-profile --profile PATH --profile-backup PATH]
    """)
    exit(0)
}

var configPath = defaultConfigPath
if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
    configPath = arguments[index + 1]
}
let expectedParentPID: Int32? = {
    guard let index = arguments.firstIndex(of: "--parent-pid"),
          arguments.indices.contains(index + 1),
          let value = Int32(arguments[index + 1]), value > 1 else { return nil }
    return value
}()

if arguments.contains("--configure-profile") || arguments.contains("--restore-profile") {
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    guard let profilePath = option("--profile"), let backupPath = option("--profile-backup") else {
        ServiceLog.error("event=agent_command command=configure_profile result=missing_arguments")
        print("--profile and --profile-backup are required", to: &standardError)
        exit(2)
    }
    do {
        if arguments.contains("--restore-profile") {
            try MihomoConfigurator.restore(config: profilePath, backup: backupPath)
            ServiceLog.info("event=agent_command command=restore_profile result=success")
        } else {
            try MihomoConfigurator.apply(MihomoConfigurator.Paths(
                config: profilePath,
                backup: backupPath,
                secretFile: option("--secret-file"),
                controllerMetadata: option("--controller-metadata"),
                daemonConfig: option("--daemon-config")
            ))
            ServiceLog.info("event=agent_command command=configure_profile result=success")
        }
        exit(0)
    } catch {
        ServiceLog.error("event=agent_command command=configure_profile result=failed")
        print("\(error.localizedDescription)", to: &standardError)
        exit(1)
    }
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
    if arguments.contains("--check-system-dns-restored") {
        guard try ProxyService.isSystemDNSRestored(configuration: configuration) else {
            ServiceLog.error(
                "event=agent_command command=check_system_dns_restored result=inconsistent"
            )
            print("system DNS restoration is not confirmed")
            exit(1)
        }
        ServiceLog.info("event=agent_command command=check_system_dns_restored result=success")
        print("system DNS restoration confirmed")
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
    var parentWatchdog: DispatchSourceTimer?
    if let expectedParentPID {
        guard getppid() == expectedParentPID else {
            throw NSError(
                domain: "MihomoAgent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "daemon parent identity changed before startup"]
            )
        }
        let timer = DispatchSource.makeTimerSource(queue: signalQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler {
            guard getppid() != expectedParentPID else { return }
            ServiceLog.error("event=agent_parent_lost action=restore_and_stop")
            semaphore.signal()
        }
        timer.resume()
        parentWatchdog = timer
    }
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
    ServiceLog.info(
        "event=agent_startup phase=service_ready elapsed_ms=\(startupClock.elapsedMilliseconds())"
    )
    semaphore.wait()
    parentWatchdog?.cancel()
    ServiceLog.info("event=agent_stopping")
    service.stop()
    _ = sources
} catch {
    ServiceLog.error("event=agent_fatal reason=startup_failed")
    exit(1)
}
