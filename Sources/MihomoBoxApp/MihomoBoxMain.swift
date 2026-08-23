import AppKit

@main
struct MihomoBoxMain {
  @MainActor
  static func main() {
    AppStartupTimeline.mark(.processStarted)
    let application = NSApplication.shared
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
