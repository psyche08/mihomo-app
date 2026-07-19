import Darwin
import Foundation

private let appSupport = URL(fileURLWithPath: "/Library/Application Support/Mihomo App")
private let daemonPath = appSupport.appendingPathComponent("mihomo-daemon")
private let daemonConfigPath = appSupport.appendingPathComponent("daemon.json")
private let profilesPath = appSupport.appendingPathComponent("profiles")
private let activeProfilePath = appSupport.appendingPathComponent("active-profile")
private let launchDaemonLabel = "dev.linsheng.mihomo.daemon"

private struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ProcessResult {
    let status: Int32
    let stdout: Data
}

@discardableResult
private func capture(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(status: process.terminationStatus, stdout: data)
}

private func runInteractive(_ executable: String, _ arguments: [String]) throws -> Never {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
}

private func appBundleURL() throws -> URL {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var cursor = executable.deletingLastPathComponent()
    while cursor.path != "/" {
        if cursor.pathExtension == "app",
           FileManager.default.fileExists(
               atPath: cursor.appendingPathComponent("Contents/Resources/scripts/install-daemon.sh").path
           ) {
            return cursor
        }
        cursor.deleteLastPathComponent()
    }

    let installed = URL(fileURLWithPath: "/Applications/MihomoBox.app")
    if FileManager.default.fileExists(
        atPath: installed.appendingPathComponent("Contents/Resources/scripts/install-daemon.sh").path
    ) {
        return installed
    }
    throw CLIError(message: "找不到 MihomoBox.app；请从 App 内运行 CLI，或将 App 安装到 /Applications。")
}

private func runInstaller(_ arguments: [String]) throws -> Never {
    let bundle = try appBundleURL()
    let installer = bundle.appendingPathComponent("Contents/Resources/scripts/install-daemon.sh")
    var command = [installer.path, "--app-bundle", bundle.path]
    command.append(contentsOf: arguments)
    if geteuid() == 0 {
        try runInteractive("/bin/bash", command)
    } else {
        command.insert("/bin/bash", at: 0)
        try runInteractive("/usr/bin/sudo", command)
    }
}

private func activeProfile() -> String? {
    guard let value = try? String(contentsOf: activeProfilePath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

private func profiles() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesPath.path)) ?? []
    return names.filter {
        let suffix = URL(fileURLWithPath: $0).pathExtension.lowercased()
        return suffix == "yaml" || suffix == "yml"
    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

private func serviceLoaded() -> Bool {
    guard let result = try? capture("/bin/launchctl", ["print", "system/\(launchDaemonLabel)"]) else {
        return false
    }
    return result.status == 0
}

private func health() -> [String: Any]? {
    guard FileManager.default.isExecutableFile(atPath: daemonPath.path),
          FileManager.default.fileExists(atPath: daemonConfigPath.path),
          let result = try? capture(daemonPath.path, ["--config", daemonConfigPath.path, "--health"]),
          result.status == 0,
          let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
        return nil
    }
    return object
}

private func printJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func printStatus(json: Bool) throws -> Int32 {
    let installed = FileManager.default.isExecutableFile(atPath: daemonPath.path)
    let loaded = serviceLoaded()
    let currentHealth = health()
    let consistent = currentHealth?["network_consistent"] as? Bool ?? false
    let current = activeProfile()

    if json {
        var object: [String: Any] = [
            "installed": installed,
            "service_loaded": loaded,
            "active_profile": current ?? NSNull(),
            "health": currentHealth ?? NSNull(),
        ]
        object["state"] = !installed ? "not_installed" : (!consistent ? "inconsistent" : (loaded ? "running" : "safely_stopped"))
        try printJSON(object)
    } else {
        let state = !installed ? "未安装" : (!consistent ? "网络状态异常" : (loaded ? "运行中" : "已安全停止"))
        print("MihomoBox: \(state)")
        print("LaunchDaemon: \(loaded ? "loaded" : "not loaded")")
        print("Active profile: \(current ?? "-")")
        if let currentHealth {
            let tun = currentHealth["tun_enabled"] as? Bool == true ? "enabled" : "disabled"
            let interface = currentHealth["tun_interface"] as? String
            let dns = currentHealth["system_dns_managed"] as? Bool == true ? "127.0.0.53" : "system default"
            print("TUN: \(tun)\(interface.map { " (\($0))" } ?? "")")
            print("System DNS: \(dns)")
            print("Network consistent: \(consistent ? "yes" : "no")")
        }
    }
    if !installed { return 1 }
    return consistent ? 0 : 2
}

private func printProfiles(json: Bool) throws {
    let current = activeProfile()
    let names = profiles()
    if json {
        let object: [String: Any] = [
            "active_profile": current as Any? ?? NSNull(),
            "profiles": names,
        ]
        try printJSON(object)
        return
    }
    if names.isEmpty {
        print("No imported profiles.")
        return
    }
    for name in names {
        print("\(name == current ? "*" : " ") \(name)")
    }
}

private func usage() {
    print("""
    usage: mihomoboxctl COMMAND

      status [--json]                 Show service and network consistency
      profile list [--json]           List imported local YAML profiles
      profile import PATH [--activate]
                                      Validate and import a local YAML profile
      profile switch NAME             Transactionally activate a profile
      install                         Install or repair the LaunchDaemon
      start                           Start the installed service safely
      restart                         Restart the service through DNS-safe shutdown
      stop                            Stop Mihomo and restore real system DNS
      uninstall                       Restore networking and remove installed files

    Mutating commands request administrator authorization through sudo.
    """)
}

private func requireNoExtraArguments(_ arguments: [String]) throws {
    guard arguments.isEmpty else { throw CLIError(message: "unexpected argument: \(arguments[0])") }
}

private func main() throws -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        usage()
        return 0
    }
    arguments.removeFirst()

    switch command {
    case "-h", "--help", "help":
        try requireNoExtraArguments(arguments)
        usage()
        return 0
    case "status":
        let json = arguments == ["--json"]
        guard arguments.isEmpty || json else { throw CLIError(message: "usage: mihomoboxctl status [--json]") }
        return try printStatus(json: json)
    case "profiles":
        let json = arguments == ["--json"]
        guard arguments.isEmpty || json else { throw CLIError(message: "usage: mihomoboxctl profiles [--json]") }
        try printProfiles(json: json)
        return 0
    case "profile":
        guard let operation = arguments.first else { throw CLIError(message: "missing profile operation") }
        arguments.removeFirst()
        switch operation {
        case "list":
            let json = arguments == ["--json"]
            guard arguments.isEmpty || json else { throw CLIError(message: "usage: mihomoboxctl profile list [--json]") }
            try printProfiles(json: json)
            return 0
        case "import":
            guard let path = arguments.first else { throw CLIError(message: "missing YAML path") }
            arguments.removeFirst()
            let activate = arguments == ["--activate"]
            guard arguments.isEmpty || activate else {
                throw CLIError(message: "usage: mihomoboxctl profile import PATH [--activate]")
            }
            let source = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CLIError(message: "profile does not exist: \(source.path)")
            }
            try runInstaller(["--import-profile", source.path] + (activate ? ["--activate"] : []))
        case "switch", "use":
            guard arguments.count == 1 else { throw CLIError(message: "usage: mihomoboxctl profile switch NAME") }
            try runInstaller(["--switch-profile", arguments[0]])
        default:
            throw CLIError(message: "unknown profile operation: \(operation)")
        }
    case "install":
        try requireNoExtraArguments(arguments)
        try runInstaller([])
    case "start":
        try requireNoExtraArguments(arguments)
        try runInstaller(["--start"])
    case "restart":
        try requireNoExtraArguments(arguments)
        try runInstaller(["--restart"])
    case "stop":
        try requireNoExtraArguments(arguments)
        try runInstaller(["--restore-network"])
    case "uninstall":
        try requireNoExtraArguments(arguments)
        try runInstaller(["--restore"])
    default:
        throw CLIError(message: "unknown command: \(command)")
    }
}

do {
    exit(try main())
} catch {
    FileHandle.standardError.write(Data("mihomoboxctl: \(error.localizedDescription)\n".utf8))
    exit(64)
}
