import AppKit
import Darwin
import Foundation
import MihomoDNSCore
import UniformTypeIdentifiers

enum ProfileCoordinatorError: Error, LocalizedError, Equatable {
  case cancelled
  case invalidName
  case invalidFile
  case invalidSubscription
  case profileTooLarge
  case busy
  case validatorUnavailable

  var errorDescription: String? {
    switch self {
    case .cancelled: "the profile operation was cancelled"
    case .invalidName: "the profile filename must end in .yaml or .yml"
    case .invalidFile: "the selected profile is not a regular file"
    case .invalidSubscription: "the subscription URL must use HTTP or HTTPS"
    case .profileTooLarge: "the profile must be between 1 byte and 16 MiB"
    case .busy: "another profile operation is already running"
    case .validatorUnavailable: "the bundled Mihomo validator is unavailable"
    }
  }
}

enum SubscriptionAuthentication: Sendable {
  case none
  case basic(username: String, password: String)
  case digest(username: String, password: String)
  case bearer(String)
  case header(name: String, value: String)
}

/// User-context profile acquisition and XPC byte transfer.
///
/// URLs and authentication values stay in this process. Only a bounded YAML
/// filename and its bytes cross the authenticated daemon boundary.
actor ProfileCoordinator {
  static let maximumProfileBytes = 16 * 1_024 * 1_024

  private let control: TrayControlClient
  private let fileManager: FileManager
  private let root: URL
  private let mihomoURL: URL?
  private var operationInFlight = false

  init(
    control: TrayControlClient,
    fileManager: FileManager = .default,
    root: URL? = nil,
    mihomoURL: URL? = Bundle.main.executableURL?
      .deletingLastPathComponent().appendingPathComponent("mihomo")
  ) {
    self.control = control
    self.fileManager = fileManager
    self.root =
      root
      ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/MihomoBox", isDirectory: true)
    self.mihomoURL = mihomoURL
  }

  func chooseAndImportLocal(daemonInstalled: Bool) async throws -> ProfileList {
    let source = try await MainActor.run { () throws -> URL in
      let panel = NSOpenPanel()
      panel.title = "Import Mihomo YAML Profile"
      panel.canChooseDirectories = false
      panel.canChooseFiles = true
      panel.allowsMultipleSelection = false
      panel.allowedContentTypes = ["yaml", "yml"].compactMap { UTType(filenameExtension: $0) }
      guard panel.runModal() == .OK, let url = panel.url else {
        throw ProfileCoordinatorError.cancelled
      }
      return url
    }
    return try await importLocal(source, daemonInstalled: daemonInstalled)
  }

  func importLocal(_ source: URL, daemonInstalled: Bool) async throws -> ProfileList {
    try await withOperation {
      guard Self.isRegularNonSymlink(source) else {
        throw ProfileCoordinatorError.invalidFile
      }
      let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ProfileCoordinatorError.invalidFile
      }
      let name = try Self.validatedName(source.lastPathComponent)
      let bytes = try Self.boundedBytes(at: source)
      try await validateWithBundledMihomo(bytes)
      return try await importingLocally(
        name: name,
        bytes: bytes,
        daemonInstalled: daemonInstalled
      )
    }
  }

  func importSubscription(
    url: URL,
    suggestedName: String? = nil,
    authentication: SubscriptionAuthentication = .none,
    daemonInstalled: Bool
  ) async throws -> ProfileList {
    try await withOperation {
      guard SubscriptionTransportPolicy.allows(url: url, authentication: authentication)
      else { throw ProfileCoordinatorError.invalidSubscription }

      var request = URLRequest(url: url, timeoutInterval: 30)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.setValue("MihomoBox/0.8", forHTTPHeaderField: "User-Agent")
      switch authentication {
      case .none:
        break
      case .basic(let username, let password):
        request.setValue(
          "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())",
          forHTTPHeaderField: "Authorization"
        )
      case .digest:
        break
      case .bearer(let token):
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      case .header(let name, let value):
        guard Self.validHeaderName(name) else {
          throw ProfileCoordinatorError.invalidSubscription
        }
        request.setValue(value, forHTTPHeaderField: name)
      }

      let bytes = try await SubscriptionDownloader.download(
        request: request,
        origin: url,
        authentication: authentication
      )
      let fallback = url.lastPathComponent.isEmpty ? "subscription.yaml" : url.lastPathComponent
      let candidate = suggestedName ?? fallback
      let name = try Self.validatedName(
        ["yaml", "yml"].contains(URL(fileURLWithPath: candidate).pathExtension.lowercased())
          ? candidate : "\(candidate).yaml"
      )
      try await validateWithBundledMihomo(bytes)
      return try await importingLocally(
        name: name,
        bytes: bytes,
        daemonInstalled: daemonInstalled
      )
    }
  }

  func promptAndImportSubscription(daemonInstalled: Bool) async throws -> ProfileList {
    let input = try await MainActor.run { try SubscriptionPrompt.run() }
    guard let url = URL(string: input.url) else {
      throw ProfileCoordinatorError.invalidSubscription
    }
    return try await importSubscription(
      url: url,
      suggestedName: input.name,
      authentication: input.authentication,
      daemonInstalled: daemonInstalled
    )
  }

  func switchProfile(named name: String, daemonInstalled: Bool) async throws -> ProfileList {
    try await withOperation {
      let name = try Self.validatedName(name)
      let local = profilesDirectory.appendingPathComponent(name)
      let localIsSafe = Self.isRegularNonSymlink(local)
      if daemonInstalled, localIsSafe {
        return try await activatingLocally(name) {
          try await control.importProfile(
            name: name,
            bytes: try Self.boundedBytes(at: local),
            activate: true
          )
        }
      } else if daemonInstalled {
        return try await activatingLocally(name) {
          try await control.switchProfile(name: name)
        }
      } else {
        try writeActive(name)
        return localList()
      }
    }
  }

  func reload() async throws -> ProfileList {
    try await withOperation { try await control.reloadProfile() }
  }

  func localState() -> ProfileList { localList() }

  private func withOperation<Value: Sendable>(
    _ body: () async throws -> Value
  ) async throws -> Value {
    guard !operationInFlight else { throw ProfileCoordinatorError.busy }
    operationInFlight = true
    defer { operationInFlight = false }
    return try await body()
  }

  private var profilesDirectory: URL { root.appendingPathComponent("profiles", isDirectory: true) }
  private var activeURL: URL { root.appendingPathComponent("active-profile") }

  private struct LocalFileBackup {
    var data: Data
    var mode: Int
  }

  private func importingLocally(
    name: String,
    bytes: Data,
    daemonInstalled: Bool
  ) async throws -> ProfileList {
    let destination = profilesDirectory.appendingPathComponent(name)
    let profileBackup = try backupRegularFile(destination)
    let activeBackup = try backupRegularFile(activeURL)
    do {
      try stage(name: name, bytes: bytes)
      try writeActive(name)
      if daemonInstalled {
        return try await control.importProfile(name: name, bytes: bytes, activate: true)
      }
      return localList()
    } catch {
      do {
        try restoreLocalFile(destination, from: profileBackup)
        try restoreLocalFile(activeURL, from: activeBackup)
      } catch {
        throw NSError(
          domain: "MihomoBoxProfileMirror",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "profile import failed and the local mirror could not be restored"
          ]
        )
      }
      throw error
    }
  }

  private func stage(name: String, bytes: Data) throws {
    try fileManager.createDirectory(
      at: profilesDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profilesDirectory.path)
    try atomicWrite(bytes, to: profilesDirectory.appendingPathComponent(name), mode: 0o600)
  }

  private func writeActive(_ name: String) throws {
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try atomicWrite(Data("\(name)\n".utf8), to: activeURL, mode: 0o600)
  }

  private func activatingLocally(
    _ name: String,
    operation: () async throws -> ProfileList
  ) async throws -> ProfileList {
    let backup = try backupRegularFile(activeURL)
    try writeActive(name)
    do {
      return try await operation()
    } catch {
      do {
        try restoreLocalFile(activeURL, from: backup)
      } catch {
        throw NSError(
          domain: "MihomoBoxProfileMirror",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "profile activation failed and the local mirror could not be restored"
          ]
        )
      }
      throw error
    }
  }

  private func backupRegularFile(_ url: URL) throws -> LocalFileBackup? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0,
      metadata.st_size <= ProfileCoordinator.maximumProfileBytes
    else { throw ProfileCoordinatorError.invalidFile }
    return LocalFileBackup(
      data: try Data(contentsOf: url),
      mode: Int(metadata.st_mode & 0o777)
    )
  }

  private func restoreLocalFile(_ url: URL, from backup: LocalFileBackup?) throws {
    if let backup {
      try atomicWrite(backup.data, to: url, mode: backup.mode)
      return
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw ProfileCoordinatorError.invalidFile
    }
    try fileManager.removeItem(at: url)
  }

  private func atomicWrite(_ data: Data, to destination: URL, mode: Int) throws {
    let staged = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      guard
        fileManager.createFile(
          atPath: staged.path, contents: nil,
          attributes: [
            .posixPermissions: mode
          ])
      else { throw CocoaError(.fileWriteUnknown) }
      let handle = try FileHandle(forWritingTo: staged)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      try fileManager.moveReplacingItem(at: staged, to: destination)
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
  }

  private func validateWithBundledMihomo(_ bytes: Data) async throws {
    guard let mihomo = mihomoURL, fileManager.isExecutableFile(atPath: mihomo.path) else {
      throw ProfileCoordinatorError.validatorUnavailable
    }
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("mihomobox-profile-verify-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: directory) }
    let profile = directory.appendingPathComponent("config.yaml")
    try atomicWrite(bytes, to: profile, mode: 0o600)

    let result = try await ProcessRunner.run(
      executable: mihomo,
      arguments: ["-t", "-d", directory.path, "-f", profile.path],
      maximumOutputBytes: 64 * 1_024
    )
    guard result.status != 0 else { return }
    throw NSError(
      domain: "MihomoBoxProfileValidation",
      code: Int(result.status),
      userInfo: [
        NSLocalizedDescriptionKey: Self.firstConfigError(result.output)
          ?? "Action failed: profile rejected by Mihomo"
      ]
    )
  }

  static func firstConfigError(_ output: String) -> String? {
    guard let line = output.split(separator: "\n").first(where: { $0.contains("level=error") })
    else { return nil }
    let source = line.split(separator: "msg=", maxSplits: 1).last.map(String.init) ?? String(line)
    let redacted = SanitizedProcessLogRedaction.redact(source)
    let trimmed = redacted.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")).prefix(160)
    return trimmed.isEmpty ? nil : "Action failed: profile rejected by Mihomo — \(trimmed)"
  }

  private func localList() -> ProfileList {
    let names =
      ((try? fileManager.contentsOfDirectory(
        at: profilesDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )) ?? []).compactMap { url -> String? in
        guard Self.isRegularNonSymlink(url),
          ["yaml", "yml"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url.lastPathComponent
      }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    let active = (try? String(contentsOf: activeURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ProfileList(
      profiles: names, activeProfile: active.flatMap { names.contains($0) ? $0 : nil })
  }

  static func boundedBytes(at url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ProfileCoordinatorError.invalidFile
    }
    guard let size = values.fileSize, size > 0, size <= maximumProfileBytes else {
      throw ProfileCoordinatorError.profileTooLarge
    }
    let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
    try validateSize(bytes)
    return bytes
  }

  static func isRegularNonSymlink(_ url: URL) -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return false }
    return metadata.st_mode & S_IFMT == S_IFREG
  }

  private static func validateSize(_ data: Data) throws {
    guard !data.isEmpty, data.count <= maximumProfileBytes else {
      throw ProfileCoordinatorError.profileTooLarge
    }
  }

  static func validatedName(_ raw: String) throws -> String {
    let suffix = URL(fileURLWithPath: raw).pathExtension.lowercased()
    guard !raw.isEmpty, raw.utf8.count <= 128, !raw.hasPrefix("."), !raw.contains("/"),
      !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      ["yaml", "yml"].contains(suffix)
    else { throw ProfileCoordinatorError.invalidName }
    return raw
  }

  static func validHeaderName(_ value: String) -> Bool {
    let restricted = [
      "authorization", "cookie", "host", "content-length", "connection",
      "transfer-encoding", "proxy-authorization",
    ]
    return !value.isEmpty && !restricted.contains(value.lowercased())
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")).contains($0)
      }
  }
}

private enum ProcessRunner {
  static func run(
    executable: URL,
    arguments: [String],
    maximumOutputBytes: Int
  ) async throws -> (status: Int32, output: String) {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      let lock = NSLock()
      var captured = Data()
      var completed = false
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        lock.lock()
        if captured.count < maximumOutputBytes {
          captured.append(data.prefix(maximumOutputBytes - captured.count))
        }
        lock.unlock()
      }
      process.terminationHandler = { process in
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        if captured.count < maximumOutputBytes {
          captured.append(tail.prefix(maximumOutputBytes - captured.count))
        }
        guard !completed else {
          lock.unlock()
          return
        }
        completed = true
        let output = String(decoding: captured, as: UTF8.self)
        lock.unlock()
        continuation.resume(returning: (process.terminationStatus, output))
      }
      do { try process.run() } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        guard !completed else {
          lock.unlock()
          return
        }
        completed = true
        lock.unlock()
        continuation.resume(throwing: error)
      }
    }
  }
}

enum SubscriptionRedirectPolicy {
  static func redirectedRequest(
    _ request: URLRequest,
    from originURL: URL,
    authentication: SubscriptionAuthentication
  ) throws -> URLRequest {
    guard
      let sourceOrigin = Self.origin(for: originURL), let url = request.url,
      let target = Self.origin(for: url),
      ["http", "https"].contains(target.scheme), url.user == nil, url.password == nil,
      !(sourceOrigin.scheme == "https" && target.scheme == "http")
    else { throw ProfileCoordinatorError.invalidSubscription }
    var redirected = request
    if target != sourceOrigin {
      redirected.setValue(nil, forHTTPHeaderField: "Authorization")
      if case .header(let name, _) = authentication {
        redirected.setValue(nil, forHTTPHeaderField: name)
      }
    }
    return redirected
  }

  private struct ComparableOrigin: Equatable {
    var scheme: String
    var host: String
    var port: Int
  }

  private static func origin(for url: URL) -> ComparableOrigin? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
      return nil
    }
    return ComparableOrigin(
      scheme: scheme,
      host: host,
      port: url.port ?? (scheme == "https" ? 443 : 80)
    )
  }
}

enum SubscriptionTransportPolicy {
  static func allows(url: URL, authentication: SubscriptionAuthentication) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      url.host != nil, url.user == nil, url.password == nil
    else { return false }
    if scheme == "https" { return true }
    if case .none = authentication { return true }
    return false
  }
}

@MainActor
private enum SubscriptionPrompt {
  struct Input: Sendable {
    var url: String
    var name: String
    var authentication: SubscriptionAuthentication
  }

  static func run() throws -> Input {
    let url = try text(
      title: "Import HTTP Subscription",
      message: "HTTP(S) subscription URL",
      placeholder: "https://example.com/profile.yaml",
      secure: false
    )
    let methods = ["None", "Basic", "Digest", "Bearer", "Custom Header"]
    let picker = NSAlert()
    picker.messageText = "HTTP Authentication"
    picker.informativeText = "Credentials remain in MihomoBox and are never sent over XPC."
    picker.addButton(withTitle: "Continue")
    picker.addButton(withTitle: "Cancel")
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
    popup.addItems(withTitles: methods)
    picker.accessoryView = popup
    guard picker.runModal() == .alertFirstButtonReturn else {
      throw ProfileCoordinatorError.cancelled
    }

    let authentication: SubscriptionAuthentication
    switch popup.titleOfSelectedItem {
    case "Basic", "Digest":
      let username = try text(
        title: "HTTP Authentication", message: "Username", placeholder: "", secure: false)
      guard !username.isEmpty, !username.contains(":"),
        !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw ProfileCoordinatorError.invalidSubscription }
      let password = try text(
        title: "HTTP Authentication", message: "Password", placeholder: "", secure: true)
      guard !password.isEmpty else { throw ProfileCoordinatorError.invalidSubscription }
      authentication =
        popup.titleOfSelectedItem == "Basic"
        ? .basic(username: username, password: password)
        : .digest(username: username, password: password)
    case "Bearer":
      let token = try text(
        title: "HTTP Authentication", message: "Bearer token", placeholder: "", secure: true)
      guard !token.isEmpty else { throw ProfileCoordinatorError.invalidSubscription }
      authentication = .bearer(token)
    case "Custom Header":
      let header = try text(
        title: "HTTP Authentication",
        message: "Header name",
        placeholder: "X-API-Key",
        secure: false
      )
      let secret = try text(
        title: "HTTP Authentication", message: "Header value", placeholder: "", secure: true)
      guard !secret.isEmpty else { throw ProfileCoordinatorError.invalidSubscription }
      authentication = .header(name: header, value: secret)
    default:
      authentication = .none
    }

    let name = try text(
      title: "Import HTTP Subscription",
      message: "Local profile filename",
      placeholder: "subscription.yaml",
      secure: false
    )
    return Input(
      url: url, name: try ProfileCoordinator.validatedName(name), authentication: authentication)
  }

  private static func text(
    title: String,
    message: String,
    placeholder: String,
    secure: Bool
  ) throws -> String {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    let field: NSTextField =
      secure
      ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
      : NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
    field.placeholderString = placeholder
    if !secure { field.stringValue = placeholder }
    alert.accessoryView = field
    guard alert.runModal() == .alertFirstButtonReturn else {
      throw ProfileCoordinatorError.cancelled
    }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class SubscriptionDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let authentication: SubscriptionAuthentication
  private let origin: Origin
  private let originURL: URL
  private var received = Data()
  private var continuation: CheckedContinuation<Result<Data, Error>, Never>?
  private var completed = false

  private struct Origin: Equatable {
    var scheme: String
    var host: String
    var port: Int

    init(scheme: String, host: String, port: Int) {
      self.scheme = scheme
      self.host = host
      self.port = port
    }

    init?(_ url: URL) {
      guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
        return nil
      }
      self.scheme = scheme
      self.host = host
      port = url.port ?? (scheme == "https" ? 443 : 80)
    }
  }

  private init(authentication: SubscriptionAuthentication, origin: Origin, originURL: URL) {
    self.authentication = authentication
    self.origin = origin
    self.originURL = originURL
  }

  static func download(
    request: URLRequest,
    origin url: URL,
    authentication: SubscriptionAuthentication
  ) async throws -> Data {
    guard let origin = Origin(url) else { throw ProfileCoordinatorError.invalidSubscription }
    let delegate = SubscriptionDownloader(
      authentication: authentication,
      origin: origin,
      originURL: url
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 45
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    return try await withTaskCancellationHandler {
      let result = await withCheckedContinuation { continuation in
        delegate.continuation = continuation
        session.dataTask(with: request).resume()
      }
      return try result.get()
    } onCancel: {
      session.invalidateAndCancel()
    }
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
    let space = challenge.protectionSpace
    let scheme = space.protocol?.lowercased() ?? ""
    let challenged = Origin(
      scheme: scheme,
      host: space.host.lowercased(),
      port: space.port > 0 ? space.port : (scheme == "https" ? 443 : 80)
    )
    guard challenged == origin else {
      let httpMethods = [
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodNTLM,
        NSURLAuthenticationMethodNegotiate,
      ]
      completionHandler(
        httpMethods.contains(space.authenticationMethod)
          ? .cancelAuthenticationChallenge : .performDefaultHandling,
        nil
      )
      return
    }
    switch authentication {
    case .basic(let username, let password)
    where space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic:
      completionHandler(
        .useCredential, URLCredential(user: username, password: password, persistence: .none))
    case .digest(let username, let password)
    where space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest:
      completionHandler(
        .useCredential, URLCredential(user: username, password: password, persistence: .none))
    default:
      let httpMethods = [
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodNTLM,
        NSURLAuthenticationMethodNegotiate,
      ]
      completionHandler(
        httpMethods.contains(space.authenticationMethod)
          ? .cancelAuthenticationChallenge : .performDefaultHandling,
        nil
      )
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let redirected = try? SubscriptionRedirectPolicy.redirectedRequest(
        request,
        from: originURL,
        authentication: authentication
      )
    else {
      finish(.failure(ProfileCoordinatorError.invalidSubscription))
      completionHandler(nil)
      return
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
      (200..<300).contains(response.statusCode),
      response.expectedContentLength <= Int64(ProfileCoordinator.maximumProfileBytes)
    else {
      finish(.failure(ProfileCoordinatorError.invalidSubscription))
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !completed else { return }
    guard received.count <= ProfileCoordinator.maximumProfileBytes - data.count else {
      finish(.failure(ProfileCoordinatorError.profileTooLarge))
      dataTask.cancel()
      return
    }
    received.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      finish(.failure(error))
    } else if received.isEmpty {
      finish(.failure(ProfileCoordinatorError.invalidSubscription))
    } else {
      finish(.success(received))
    }
  }

  private func finish(_ result: Result<Data, Error>) {
    guard !completed else { return }
    completed = true
    continuation?.resume(returning: result)
    continuation = nil
  }
}

extension FileManager {
  fileprivate func moveReplacingItem(at source: URL, to destination: URL) throws {
    if fileExists(atPath: destination.path) {
      _ = try replaceItemAt(destination, withItemAt: source)
    } else {
      try moveItem(at: source, to: destination)
    }
  }
}
