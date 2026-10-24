import AppKit

@main
struct MihomoBoxMain {
  @MainActor
  static func main() {
    AppStartupTimeline.mark(.processStarted)
    let application = NSApplication.shared
    if ProcessInfo.processInfo.arguments.dropFirst().contains(AppProxyExtensionActivationCommand.argument) {
      guard Array(ProcessInfo.processInfo.arguments.dropFirst()) == [AppProxyExtensionActivationCommand.argument] else {
        FileHandle.standardError.write(Data("Expected only --activate-app-proxy-extension\n".utf8)); exit(1)
      }
      application.setActivationPolicy(.accessory)
      let command = AppProxyExtensionActivationCommand { outcome in
        if let data = try? JSONEncoder().encode(outcome) {
          FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        exit(outcome.exitCode)
      }
      DispatchQueue.main.async { command.start() }
      application.run()
      withExtendedLifetime(command) {}
      return
    }
    let delegate = AppDelegate(coordinator: AppComposition.live())

    // MihomoBox is a menu-bar application. Creating the NSApplication here,
    // rather than through a SwiftUI scene, keeps startup windowless and makes
    // AppKit the single owner of the process event loop.
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()

    // NSApplication does not retain its delegate. Keep the local alive until
    // the event loop has finished.
    withExtendedLifetime(delegate) {}
  }
}
