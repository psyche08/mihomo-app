import Darwin
import Foundation
import MihomoControl
import Security

enum InstallerCoordinatorError: Error, LocalizedError {
  case appBundleUnavailable
  case installerMissing
  case cancelled
  case profileRejected
  case timedOut
  case failed

  var errorDescription: String? {
    switch self {
    case .appBundleUnavailable: "MihomoBox is not running from an App bundle"
    case .installerMissing: "the signed installer is missing from the App bundle"
    case .cancelled: "the installation was cancelled"
    case .profileRejected: "Mihomo rejected the selected profile; import a valid profile"
    case .timedOut: "the daemon did not become ready in time"
    case .failed: "the privileged installer did not complete"
    }
  }
}

/// The only App-side path to administrator authorization.
///
/// Normal runtime mutations never enter this type. The bundled signed installer
/// remains responsible for installing or repairing the LaunchDaemon.
actor InstallerCoordinator {
  private struct ProfileSnapshot: Sendable {
    let name: String
    let bytes: Data
  }

  private struct ExactSigningRequirements {
    let app: String
    let caller: String
  }

  private static let callerRelativeExecutable = "Contents/MacOS/mihomo-app"
  private static let installedDaemonURL = URL(
    fileURLWithPath: "/Library/Application Support/Mihomo App/mihomo-daemon"
  )
  private let bundleURL: URL?
  private let control: TrayControlClient

  init(
    bundleURL: URL? = Bundle.main.bundleURL,
    control: TrayControlClient = TrayControlClient()
  ) {
    self.bundleURL = bundleURL
    self.control = control
  }

  var installationActionsAvailable: Bool {
    guard let bundleURL, bundleURL.pathExtension == "app" else { return false }
    let script = bundleURL.appendingPathComponent(
      "Contents/Resources/scripts/install-daemon.sh"
    )
    let caller = bundleURL.appendingPathComponent(Self.callerRelativeExecutable)
    return Self.isDirectoryNonSymlink(bundleURL)
      && Self.isRegularExecutable(caller)
      && Self.isRegularExecutable(script)
  }

  func installOrRepair(initialProfile: URL? = nil) async throws {
    guard let bundleURL, bundleURL.pathExtension == "app" else {
      throw InstallerCoordinatorError.appBundleUnavailable
    }
    let script = bundleURL.appendingPathComponent(
      "Contents/Resources/scripts/install-daemon.sh"
    )
    guard Self.isRegularExecutable(script) else {
      throw InstallerCoordinatorError.installerMissing
    }
    let requirements = try Self.exactSigningRequirements(
      bundleURL: bundleURL,
      callerRelativeExecutable: Self.callerRelativeExecutable
    )

    let daemonWasInstalled = Self.isRegularExecutable(Self.installedDaemonURL)
    // Freeze optional profile bytes in the unprivileged process before asking
    // for authorization. Root must never reopen a user-controlled profile path
    // after the administrator prompt. Once the daemon is installed, the bytes
    // cross the authenticated typed XPC profile operation.
    let profile = try initialProfile.map(Self.snapshotProfile)
    let command = Self.bootstrapCommand(
      sourceBundlePath: bundleURL.standardizedFileURL.path,
      appRequirement: requirements.app,
      callerRequirement: requirements.caller,
      callerRelativeExecutable: Self.callerRelativeExecutable,
      installerArguments: [],
      detached: false
    )
    let source = "do shell script \(Self.appleScriptQuote(command)) with administrator privileges"
    AppLog.info("event=privileged_installer action=install phase=started")
    let result = try await Self.runAppleScript(source)
    guard result.status == 0 else {
      let message = result.output
      if result.status == 1
        && (message.contains("(-128)")
          || message.localizedCaseInsensitiveContains("User canceled"))
      {
        AppLog.info("event=privileged_installer action=install result=cancelled")
        throw InstallerCoordinatorError.cancelled
      }
      AppLog.error(
        "event=privileged_installer action=install result=failed reason=\(Self.classification(message))"
      )
      if message.localizedCaseInsensitiveContains("test failed")
        || message.localizedCaseInsensitiveContains("configuration file")
      {
        throw InstallerCoordinatorError.profileRejected
      }
      if message.localizedCaseInsensitiveContains("timed out waiting for") {
        throw InstallerCoordinatorError.timedOut
      }
      throw InstallerCoordinatorError.failed
    }
    if let profile {
      do {
        _ = try await control.importProfile(
          name: profile.name,
          bytes: profile.bytes,
          activate: true
        )
      } catch {
        AppLog.error("event=privileged_installer action=profile_activate result=failed")
        if !daemonWasInstalled {
          do {
            _ = try await control.stopAgentAndRestore()
            AppLog.info(
              "event=privileged_installer action=profile_activate fallback=network_restored")
          } catch {
            AppLog.error(
              "event=privileged_installer action=profile_activate fallback=restore_failed")
            throw InstallerCoordinatorError.failed
          }
        }
        throw InstallerCoordinatorError.profileRejected
      }
    }
    AppLog.info("event=privileged_installer action=install result=success")
  }

  private static func runAppleScript(_ source: String) async throws -> (
    status: Int32, output: String
  ) {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", source]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      let lock = NSLock()
      var captured = Data()
      var completed = false
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        lock.lock()
        if captured.count < 64 * 1_024 {
          captured.append(data.prefix(64 * 1_024 - captured.count))
        }
        lock.unlock()
      }
      process.terminationHandler = { process in
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        if captured.count < 64 * 1_024 {
          captured.append(tail.prefix(64 * 1_024 - captured.count))
        }
        guard !completed else {
          lock.unlock()
          return
        }
        completed = true
        let data = captured
        lock.unlock()
        continuation.resume(
          returning: (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
          ))
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

  static func classification(_ value: String) -> String {
    if value.localizedCaseInsensitiveContains("test failed") { return "profile_rejected" }
    if value.localizedCaseInsensitiveContains("configuration file") { return "profile_rejected" }
    if value.localizedCaseInsensitiveContains("timed out") { return "timeout" }
    return "other"
  }

  static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  static func appleScriptQuote(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
  }

  /// Builds the complete privileged boundary. Until both exact requirements
  /// have accepted the root-owned snapshot, every executable here is a fixed
  /// Apple system tool selected by signed Swift code.
  static func bootstrapCommand(
    sourceBundlePath: String,
    appRequirement: String,
    callerRequirement: String,
    callerRelativeExecutable: String,
    installerArguments: [String],
    detached: Bool
  ) -> String {
    precondition(callerRelativeExecutable.hasPrefix("Contents/MacOS/"))
    precondition(!callerRelativeExecutable.contains(".."))

    let source = shellQuote(sourceBundlePath)
    let appRequirementArgument = shellQuote("=\(appRequirement)")
    let callerRequirementArgument = shellQuote("=\(callerRequirement)")
    let forwardedArguments = installerArguments.map(shellQuote).joined(separator: " ")
    let invocation = """
      /bin/bash "$installer" --verified-app-snapshot "$snapshot"\(forwardedArguments.isEmpty ? "" : " \(forwardedArguments)")
      """

    var body = """
      set -eu
      PATH=/usr/bin:/bin:/usr/sbin:/sbin
      export PATH
      umask 077
      stage=$(/usr/bin/mktemp -d /private/tmp/mihomobox-bootstrap.XXXXXX)
      case "$stage" in
        /private/tmp/mihomobox-bootstrap.*) ;;
        *) exit 1 ;;
      esac
      /bin/chmod 0700 "$stage"
      [ "$('/usr/bin/stat' -f '%u:%Lp' "$stage")" = "0:700" ]
      cleanup() { /bin/rm -rf -- "$stage"; }
      trap cleanup EXIT HUP INT TERM
      snapshot="$stage/MihomoBox.app"
      /usr/bin/ditto \(source) "$snapshot"
      /usr/bin/codesign --verify --deep --strict --all-architectures \
        -R \(appRequirementArgument) "$snapshot"
      caller="$snapshot/\(callerRelativeExecutable)"
      [ -f "$caller" ] && [ ! -L "$caller" ] && [ -x "$caller" ]
      /usr/bin/codesign --verify --strict --all-architectures \
        -R \(callerRequirementArgument) "$caller"
      installer="$snapshot/Contents/Resources/scripts/install-daemon.sh"
      [ -f "$installer" ] && [ ! -L "$installer" ] && [ -x "$installer" ]
      """

    if detached {
      let worker = """
        set -eu
        stage=$1
        shift
        trap '/bin/rm -rf -- "$stage/MihomoBox.app"' EXIT HUP INT TERM
        "$@"
        """
      body += """

        log="$stage/install.log"
        pid_file="$stage/install.pid"
        /usr/bin/nohup /bin/sh -c \(shellQuote(worker)) mihomobox-installer \
          "$stage" \(invocation) >"$log" 2>&1 </dev/null &
        install_pid=$!
        /usr/bin/printf '%s\n' "$install_pid" >"$pid_file"
        /bin/chmod 0600 "$log" "$pid_file"
        trap - EXIT HUP INT TERM
        /bin/echo "MihomoBox daemon installation started"
        /bin/echo "pid: $install_pid"
        /bin/echo "log: $log"
        """
    } else {
      body += "\n\(invocation)"
    }
    return "/bin/sh -c \(shellQuote(body))"
  }

  static func isRegularExecutable(_ url: URL) -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o111 != 0
    else { return false }
    return true
  }

  static func isRegularFile(_ url: URL) -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG
    else { return false }
    return true
  }

  private static func snapshotProfile(_ url: URL) throws -> ProfileSnapshot {
    let name = url.lastPathComponent
    guard !name.isEmpty, name.count <= 128, !name.hasPrefix("."),
      !name.contains("/"),
      !name.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      }), ["yaml", "yml"].contains(url.pathExtension.lowercased())
    else { throw InstallerCoordinatorError.profileRejected }

    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw InstallerCoordinatorError.profileRejected }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size > 0,
      metadata.st_size <= Int64(ProfileCoordinator.maximumProfileBytes)
    else { throw InstallerCoordinatorError.profileRejected }

    var bytes = Data()
    bytes.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      guard count >= 0 else { throw InstallerCoordinatorError.profileRejected }
      if count == 0 { break }
      guard bytes.count + count <= ProfileCoordinator.maximumProfileBytes else {
        throw InstallerCoordinatorError.profileRejected
      }
      bytes.append(contentsOf: buffer.prefix(count))
    }
    guard !bytes.isEmpty else { throw InstallerCoordinatorError.profileRejected }
    return ProfileSnapshot(name: name, bytes: bytes)
  }

  static func isDirectoryNonSymlink(_ url: URL) -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR
    else { return false }
    return true
  }

  private static func exactSigningRequirements(
    bundleURL: URL,
    callerRelativeExecutable: String
  ) throws -> ExactSigningRequirements {
    guard isDirectoryNonSymlink(bundleURL) else {
      throw InstallerCoordinatorError.appBundleUnavailable
    }
    let caller = bundleURL.appendingPathComponent(callerRelativeExecutable)
    guard isRegularExecutable(caller),
      currentExecutableURL()?.resolvingSymlinksInPath().standardizedFileURL
        == caller.resolvingSymlinksInPath().standardizedFileURL
    else { throw InstallerCoordinatorError.failed }

    let leaf = try SigningCertificateRequirement.currentProcess()
    try SigningCertificateRequirement.validateStaticCode(at: bundleURL, requirement: leaf)
    let callerRequirement = try currentProcessExactRequirement(leafRequirement: leaf)
    try SigningCertificateRequirement.validateStaticCode(
      at: caller,
      requirement: callerRequirement
    )

    let app = try SigningCertificateRequirement.exactStaticCodeRequirement(
      at: bundleURL,
      leafRequirement: leaf
    )
    try SigningCertificateRequirement.validateStaticCode(at: bundleURL, requirement: app)
    try SigningCertificateRequirement.validateStaticCode(
      at: caller,
      requirement: callerRequirement
    )
    return ExactSigningRequirements(app: app, caller: callerRequirement)
  }

  /// The caller requirement must describe the Mach-O already executing this
  /// signed Swift code. Deriving it from the bundle path would let a complete
  /// same-certificate App replacement become the new authority before root
  /// takes its private snapshot.
  private static func currentProcessExactRequirement(
    leafRequirement: String
  ) throws -> String {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
      let dynamicCode
    else { throw InstallerCoordinatorError.failed }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
      let staticCode
    else { throw InstallerCoordinatorError.failed }
    var designated: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &designated) == errSecSuccess,
      let designated
    else { throw InstallerCoordinatorError.failed }
    var designatedText: CFString?
    guard SecRequirementCopyString(designated, [], &designatedText) == errSecSuccess,
      let designatedText
    else { throw InstallerCoordinatorError.failed }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [String: Any],
      let unique = values[kSecCodeInfoUnique as String] as? Data,
      !unique.isEmpty
    else { throw InstallerCoordinatorError.failed }
    let cdhash = unique.map { String(format: "%02x", $0) }.joined()
    let exact =
      "(\(designatedText as String)) and (\(leafRequirement)) "
      + "and cdhash H\"\(cdhash)\""
    var parsed: SecRequirement?
    guard SecRequirementCreateWithString(exact as CFString, [], &parsed) == errSecSuccess,
      parsed != nil
    else { throw InstallerCoordinatorError.failed }
    return exact
  }

  private static func currentExecutableURL() -> URL? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(size))
    let status = buffer.withUnsafeMutableBufferPointer {
      _NSGetExecutablePath($0.baseAddress, &size)
    }
    guard status == 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer))
  }
}
