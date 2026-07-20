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
    var exitCode: Int32 = 64
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

private func runInteractive(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
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

private func installerCommand(_ arguments: [String]) throws -> (URL, URL, [String]) {
    let bundle = try appBundleURL()
    let installer = bundle.appendingPathComponent("Contents/Resources/scripts/install-daemon.sh")
    var command = [installer.path, "--app-bundle", bundle.path]
    command.append(contentsOf: arguments)
    return (bundle, installer, command)
}

private func runInstaller(_ arguments: [String]) throws -> Int32 {
    let (_, _, command) = try installerCommand(arguments)
    if geteuid() == 0 {
        return try runInteractive("/bin/bash", command)
    } else {
        return try runInteractive("/usr/bin/sudo", ["/bin/bash"] + command)
    }
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func appleScriptQuote(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}

private func runInstallerWithAdministratorDialog(_ arguments: [String]) throws -> Int32 {
    let (_, _, command) = try installerCommand(arguments)
    let shellCommand = (["/bin/bash"] + command).map(shellQuote).joined(separator: " ")
    let script = "do shell script \(appleScriptQuote(shellCommand)) with administrator privileges"
    return try runInteractive("/usr/bin/osascript", ["-e", script])
}

private enum SubscriptionAuthentication {
    case none
    case basic(username: String, password: String)
    case digest(username: String, password: String)
    case bearer(token: String)
    case header(name: String, value: String)
}

private struct SubscriptionImport {
    let url: URL
    let name: String
    let authentication: SubscriptionAuthentication
    let activate: Bool
    let administratorDialog: Bool
}

private final class SubscriptionDownloadDelegate: NSObject, URLSessionDataDelegate {
    private let authentication: SubscriptionAuthentication
    private let originHost: String
    private let originScheme: String
    private let originPort: Int
    private let maximumSize = 16 * 1_024 * 1_024
    private let semaphore = DispatchSemaphore(value: 0)
    private var received = Data()
    private var result: Result<Data, Error>?

    init(authentication: SubscriptionAuthentication, origin: URL) {
        self.authentication = authentication
        originHost = origin.host?.lowercased() ?? ""
        originScheme = origin.scheme?.lowercased() ?? ""
        originPort = origin.port ?? (originScheme == "https" ? 443 : 80)
    }

    func waitForResult() throws -> Data {
        semaphore.wait()
        return try result?.get() ?? {
            throw CLIError(message: "subscription download did not complete", exitCode: 1)
        }()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let method = challenge.protectionSpace.authenticationMethod
        let challengeScheme = challenge.protectionSpace.protocol?.lowercased() ?? ""
        let challengePort = challenge.protectionSpace.port > 0
            ? challenge.protectionSpace.port
            : (challengeScheme == "https" ? 443 : 80)
        guard challenge.protectionSpace.host.lowercased() == originHost,
              challengeScheme == originScheme,
              challengePort == originPort else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch authentication {
        case let .basic(username, password) where method == NSURLAuthenticationMethodHTTPBasic:
            completionHandler(
                .useCredential,
                URLCredential(user: username, password: password, persistence: .none)
            )
        case let .digest(username, password) where method == NSURLAuthenticationMethodHTTPDigest:
            completionHandler(
                .useCredential,
                URLCredential(user: username, password: password, persistence: .none)
            )
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil else {
            fail(CLIError(message: "subscription redirect used an unsupported URL scheme", exitCode: 1))
            completionHandler(nil)
            return
        }
        guard !(originScheme == "https" && scheme == "http") else {
            fail(CLIError(message: "subscription redirect attempted to downgrade HTTPS", exitCode: 1))
            completionHandler(nil)
            return
        }
        var redirected = request
        let redirectPort = url.port ?? (scheme == "https" ? 443 : 80)
        if url.host?.lowercased() != originHost || scheme != originScheme || redirectPort != originPort {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            if case let .header(name, _) = authentication {
                redirected.setValue(nil, forHTTPHeaderField: name)
            }
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            fail(CLIError(
                message: status.map { "subscription request returned HTTP \($0)" }
                    ?? "subscription server returned an invalid response",
                exitCode: 1
            ))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > maximumSize {
            fail(CLIError(message: "subscription profile exceeds 16 MiB", exitCode: 1))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard result == nil else { return }
        guard received.count + data.count <= maximumSize else {
            fail(CLIError(message: "subscription profile exceeds 16 MiB", exitCode: 1))
            dataTask.cancel()
            return
        }
        received.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if result == nil {
            if error != nil {
                fail(CLIError(message: "subscription download failed", exitCode: 1))
            } else if received.isEmpty {
                fail(CLIError(message: "subscription returned an empty profile", exitCode: 1))
            } else {
                result = .success(received)
            }
        }
        semaphore.signal()
    }

    private func fail(_ error: Error) {
        if result == nil {
            result = .failure(error)
        }
    }
}

private func validateProfileName(_ name: String) throws {
    let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
    guard !name.isEmpty, name.utf8.count <= 128,
          !name.hasPrefix("."), !name.contains("/"),
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          suffix == "yaml" || suffix == "yml" else {
        throw CLIError(message: "profile name must be a safe .yaml or .yml filename")
    }
}

private func validateHeaderName(_ name: String) throws {
    let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    let forbidden = ["host", "content-length", "connection", "transfer-encoding", "proxy-authorization"]
    guard !name.isEmpty,
          name.unicodeScalars.allSatisfy(token.contains),
          !forbidden.contains(name.lowercased()) else {
        throw CLIError(message: "invalid or restricted custom HTTP header name")
    }
}

private func validatedSubscriptionURL(_ value: String) throws -> URL {
    guard let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          components.host != nil,
          components.user == nil, components.password == nil,
          let url = components.url else {
        throw CLIError(message: "subscription URL must be HTTP(S) and must not embed credentials")
    }
    return url
}

private func downloadSubscription(_ subscription: SubscriptionImport) throws -> Data {
    var request = URLRequest(url: subscription.url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 30
    request.setValue("MihomoBox/0.1", forHTTPHeaderField: "User-Agent")
    switch subscription.authentication {
    case .none, .digest:
        break
    case let .basic(username, password):
        let credential = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
    case let .bearer(token):
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    case let .header(name, value):
        request.setValue(value, forHTTPHeaderField: name)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 45
    let delegate = SubscriptionDownloadDelegate(
        authentication: subscription.authentication,
        origin: subscription.url
    )
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    session.dataTask(with: request).resume()
    defer { session.invalidateAndCancel() }
    return try delegate.waitForResult()
}

private func readSecret(prompt: String, fromStandardInput: Bool) throws -> String {
    let value: String
    if fromStandardInput {
        value = readLine(strippingNewline: true) ?? ""
    } else if let pointer = getpass(prompt) {
        value = String(cString: pointer)
    } else {
        value = ""
    }
    guard !value.isEmpty, !value.contains("\r"), !value.contains("\n") else {
        throw CLIError(message: "authentication secret must not be empty")
    }
    return value
}

private func appleScriptValue(_ source: String) -> String? {
    guard let result = try? capture("/usr/bin/osascript", ["-e", source]), result.status == 0 else {
        return nil
    }
    let value = String(decoding: result.stdout, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func interactiveSubscriptionImport() throws -> SubscriptionImport? {
    guard let urlText = appleScriptValue(
        "text returned of (display dialog \"HTTP(S) subscription URL\" default answer \"\" buttons {\"Cancel\", \"Continue\"} default button \"Continue\" cancel button \"Cancel\")"
    ) else { return nil }
    guard let method = appleScriptValue(
        "item 1 of (choose from list {\"None\", \"Basic\", \"Digest\", \"Bearer\", \"Custom Header\"} with prompt \"HTTP authentication\" default items {\"None\"})"
    ) else { return nil }

    let authentication: SubscriptionAuthentication
    switch method {
    case "None":
        authentication = .none
    case "Basic", "Digest":
        guard let username = appleScriptValue(
            "text returned of (display dialog \"Username\" default answer \"\" buttons {\"Cancel\", \"Continue\"} default button \"Continue\" cancel button \"Cancel\")"
        ), let password = appleScriptValue(
            "text returned of (display dialog \"Password\" default answer \"\" with hidden answer buttons {\"Cancel\", \"Continue\"} default button \"Continue\" cancel button \"Cancel\")"
        ) else { return nil }
        guard !username.contains(":"), !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CLIError(message: "invalid HTTP authentication username")
        }
        authentication = method == "Basic"
            ? .basic(username: username, password: password)
            : .digest(username: username, password: password)
    case "Bearer":
        guard let token = appleScriptValue(
            "text returned of (display dialog \"Bearer token\" default answer \"\" with hidden answer buttons {\"Cancel\", \"Continue\"} default button \"Continue\" cancel button \"Cancel\")"
        ) else { return nil }
        authentication = .bearer(token: token)
    case "Custom Header":
        guard let name = appleScriptValue(
            "text returned of (display dialog \"Header name (for example X-API-Key)\" default answer \"X-API-Key\" buttons {\"Cancel\", \"Continue\"} default button \"Continue\" cancel button \"Cancel\")"
        ), let value = appleScriptValue(
            "text returned of (display dialog \"Header value\" default answer \"\" with hidden answer buttons {\"Cancel\", \"Continue\"} default button \"Continue\" cancel button \"Cancel\")"
        ) else { return nil }
        try validateHeaderName(name)
        authentication = .header(name: name, value: value)
    default:
        throw CLIError(message: "unsupported HTTP authentication method")
    }

    guard let name = appleScriptValue(
        "text returned of (display dialog \"Local profile filename\" default answer \"subscription.yaml\" buttons {\"Cancel\", \"Continue\"} default button \"Continue\" cancel button \"Cancel\")"
    ) else { return nil }
    try validateProfileName(name)
    let activate = appleScriptValue(
        "button returned of (display dialog \"Activate this profile after import?\" buttons {\"Import Only\", \"Import & Activate\"} default button \"Import & Activate\")"
    ) == "Import & Activate"
    return SubscriptionImport(
        url: try validatedSubscriptionURL(urlText),
        name: name,
        authentication: authentication,
        activate: activate,
        administratorDialog: true
    )
}

private func parseSubscriptionImport(_ arguments: [String]) throws -> SubscriptionImport? {
    if arguments == ["--interactive"] {
        return try interactiveSubscriptionImport()
    }
    guard let urlText = arguments.first, !urlText.hasPrefix("--") else {
        throw CLIError(message: "usage: mihomoboxctl profile import-url URL [options]")
    }

    var name = "subscription.yaml"
    var authMode = "none"
    var username: String?
    var headerName: String?
    var activate = false
    var secretStdin = false
    var remaining = Array(arguments.dropFirst())
    while let option = remaining.first {
        remaining.removeFirst()
        switch option {
        case "--name":
            guard let value = remaining.first else { throw CLIError(message: "--name requires a value") }
            remaining.removeFirst()
            name = value
        case "--auth":
            guard let value = remaining.first else { throw CLIError(message: "--auth requires a value") }
            remaining.removeFirst()
            authMode = value.lowercased()
        case "--username":
            guard let value = remaining.first else { throw CLIError(message: "--username requires a value") }
            remaining.removeFirst()
            username = value
        case "--header":
            guard let value = remaining.first else { throw CLIError(message: "--header requires a value") }
            remaining.removeFirst()
            headerName = value
        case "--activate":
            activate = true
        case "--secret-stdin":
            secretStdin = true
        default:
            throw CLIError(message: "unknown import-url option: \(option)")
        }
    }

    try validateProfileName(name)
    let authentication: SubscriptionAuthentication
    switch authMode {
    case "none":
        guard username == nil, headerName == nil, !secretStdin else {
            throw CLIError(message: "authentication options require --auth")
        }
        authentication = .none
    case "basic", "digest":
        guard let username, !username.isEmpty, !username.contains(":"),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CLIError(message: "--auth \(authMode) requires a valid --username")
        }
        guard headerName == nil else { throw CLIError(message: "--header requires --auth header") }
        let password = try readSecret(prompt: "HTTP password: ", fromStandardInput: secretStdin)
        authentication = authMode == "basic"
            ? .basic(username: username, password: password)
            : .digest(username: username, password: password)
    case "bearer":
        guard username == nil, headerName == nil else {
            throw CLIError(message: "bearer authentication does not accept username/header options")
        }
        authentication = .bearer(
            token: try readSecret(prompt: "Bearer token: ", fromStandardInput: secretStdin)
        )
    case "header":
        guard username == nil, let headerName else {
            throw CLIError(message: "--auth header requires --header NAME")
        }
        try validateHeaderName(headerName)
        authentication = .header(
            name: headerName,
            value: try readSecret(prompt: "HTTP header value: ", fromStandardInput: secretStdin)
        )
    default:
        throw CLIError(message: "--auth must be none, basic, digest, bearer, or header")
    }

    return SubscriptionImport(
        url: try validatedSubscriptionURL(urlText),
        name: name,
        authentication: authentication,
        activate: activate,
        administratorDialog: false
    )
}

private func importSubscription(_ subscription: SubscriptionImport) throws -> Int32 {
    let data = try downloadSubscription(subscription)
    let temporaryDirectory = URL(fileURLWithPath: "/private/tmp")
        .appendingPathComponent("mihomobox-subscription-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let profile = temporaryDirectory.appendingPathComponent(subscription.name)
    guard FileManager.default.createFile(
        atPath: profile.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw CLIError(message: "could not create secure temporary profile", exitCode: 1)
    }
    let file = try FileHandle(forWritingTo: profile)
    do {
        try file.write(contentsOf: data)
        try file.close()
    } catch {
        try? file.close()
        throw error
    }

    let arguments = ["--import-profile", profile.path] + (subscription.activate ? ["--activate"] : [])
    return subscription.administratorDialog
        ? try runInstallerWithAdministratorDialog(arguments)
        : try runInstaller(arguments)
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
    let runtimeReady = currentHealth?["controller_reachable"] as? Bool ?? false
    let current = activeProfile()

    if json {
        var object: [String: Any] = [
            "installed": installed,
            "service_loaded": loaded,
            "active_profile": current ?? NSNull(),
            "health": currentHealth ?? NSNull(),
        ]
        object["runtime_ready"] = runtimeReady
        object["state"] = !installed
            ? "not_installed"
            : (!consistent
                ? "inconsistent"
                : (loaded ? (runtimeReady ? "running" : "runtime_unavailable") : "safely_stopped"))
        try printJSON(object)
    } else {
        let state = !installed
            ? "未安装"
            : (!consistent
                ? "网络状态异常"
                : (loaded ? (runtimeReady ? "运行中" : "运行时不可用（网络已安全恢复）") : "已安全停止"))
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
    if !consistent { return 2 }
    return loaded && !runtimeReady ? 3 : 0
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
      profile import-url URL [--name FILE] [--activate]
        [--auth none|basic|digest|bearer|header]
        [--username USER] [--header NAME] [--secret-stdin]
                                      Download, validate, and import HTTP(S) YAML
      profile switch NAME             Transactionally activate a profile
      install                         Install or repair the LaunchDaemon
      start                           Start the installed service safely
      restart                         Restart the service through DNS-safe shutdown
      stop                            Stop Mihomo and restore real system DNS
      uninstall                       Restore networking and remove installed files

    Authentication secrets are read from a hidden prompt unless --secret-stdin
    is used. Secrets and subscription URLs are never passed to the root installer.
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
            return try runInstaller(["--import-profile", source.path] + (activate ? ["--activate"] : []))
        case "import-url":
            guard let subscription = try parseSubscriptionImport(arguments) else { return 0 }
            return try importSubscription(subscription)
        case "switch", "use":
            guard arguments.count == 1 else { throw CLIError(message: "usage: mihomoboxctl profile switch NAME") }
            return try runInstaller(["--switch-profile", arguments[0]])
        default:
            throw CLIError(message: "unknown profile operation: \(operation)")
        }
    case "install":
        try requireNoExtraArguments(arguments)
        return try runInstaller([])
    case "start":
        try requireNoExtraArguments(arguments)
        return try runInstaller(["--start"])
    case "restart":
        try requireNoExtraArguments(arguments)
        return try runInstaller(["--restart"])
    case "stop":
        try requireNoExtraArguments(arguments)
        return try runInstaller(["--restore-network"])
    case "uninstall":
        try requireNoExtraArguments(arguments)
        return try runInstaller(["--restore"])
    default:
        throw CLIError(message: "unknown command: \(command)")
    }
}

do {
    exit(try main())
} catch let error as CLIError {
    FileHandle.standardError.write(Data("mihomoboxctl: \(error.localizedDescription)\n".utf8))
    exit(error.exitCode)
} catch {
    FileHandle.standardError.write(Data("mihomoboxctl: operation failed (\(error.localizedDescription))\n".utf8))
    exit(1)
}
