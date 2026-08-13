/// One process-wide non-reentrant mutation coordinator shared by the AppKit
/// tray and the SwiftUI dashboard.
///
/// The daemon remains the authoritative privilege boundary. This coordinator
/// prevents two in-process UI entry points from interleaving multi-step
/// before/mutate/readback transactions while one App process is alive.
public actor AppMutationCoordinator {
  public static let shared = AppMutationCoordinator()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  public func withLock<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    await acquire()
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  public func tryWithLock<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value? {
    guard !held else { return nil }
    held = true
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    guard !waiters.isEmpty else {
      held = false
      return
    }
    waiters.removeFirst().resume()
  }
}
