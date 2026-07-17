import Darwin
import Foundation
import MihomoDNSCore

private let defaultConfigPath = "/Library/Application Support/Mihomo App/daemon.json"
private let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: mihomo-daemon [--config PATH] [--check] [--restore-system-dns]")
    exit(0)
}

var configPath = defaultConfigPath
if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
    configPath = arguments[index + 1]
}

do {
    let configuration = try ProxyConfiguration.load(path: configPath)
    if arguments.contains("--check") {
        print("configuration valid")
        exit(0)
    }
    if arguments.contains("--restore-system-dns") {
        try ProxyService.restoreSystemDNS(configuration: configuration)
        print("system DNS restored")
        exit(0)
    }

    signal(SIGPIPE, SIG_IGN)
    let service = ProxyService(configuration: configuration)
    let signalQueue = DispatchQueue(label: "dev.linsheng.mihomo-app.signal")
    let semaphore = DispatchSemaphore(value: 0)
    var sources: [DispatchSourceSignal] = []
    for value in [SIGTERM, SIGINT] {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: signalQueue)
        source.setEventHandler {
            semaphore.signal()
        }
        source.resume()
        sources.append(source)
    }

    try service.start()
    semaphore.wait()
    ServiceLog.info("event=service_stopping")
    service.stop()
    _ = sources
} catch {
    ServiceLog.error("event=fatal error=\(String(describing: error))")
    exit(1)
}
