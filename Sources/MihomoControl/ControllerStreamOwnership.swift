/// Tracks which control peer owns each controller stream.
///
/// The daemon serializes access to this value with its stream lock. Keeping the
/// ownership rules here lets the daemon and its regression tests use the same
/// authorization and cleanup logic without exposing controller stream objects.
public struct ControllerStreamOwnership {
  private enum Owner: Equatable {
    case peer(ObjectIdentifier)
    case internalCall
  }

  private var owners: [String: Owner] = [:]

  public init() {}

  /// Registers a newly opened stream. Ownerless streams are reserved for
  /// direct unit/internal calls and are distinct from an unknown identifier.
  @discardableResult
  public mutating func register(identifier: String, owner: ObjectIdentifier?) -> Bool {
    guard owners[identifier] == nil else { return false }
    if let owner {
      owners[identifier] = .peer(owner)
    } else {
      owners[identifier] = .internalCall
    }
    return true
  }

  /// Returns whether the caller may continue using the stream.
  public func allows(identifier: String, owner: ObjectIdentifier?) -> Bool {
    guard let registeredOwner = owners[identifier] else { return false }
    switch (registeredOwner, owner) {
    case (.peer(let expected), .some(let actual)):
      return expected == actual
    case (.internalCall, .none):
      return true
    default:
      return false
    }
  }

  /// Removes a stream only when the caller owns it.
  @discardableResult
  public mutating func remove(identifier: String, owner: ObjectIdentifier?) -> Bool {
    guard allows(identifier: identifier, owner: owner) else { return false }
    owners.removeValue(forKey: identifier)
    return true
  }

  /// Removes ownership unconditionally for daemon-controlled cleanup such as
  /// receive failure or idle expiry.
  @discardableResult
  public mutating func remove(identifier: String) -> Bool {
    owners.removeValue(forKey: identifier) != nil
  }

  /// Removes and returns every stream identifier owned by a disconnected peer.
  public mutating func removeAll(ownedBy owner: ObjectIdentifier) -> [String] {
    let identifiers = owners.compactMap { identifier, registeredOwner in
      registeredOwner == .peer(owner) ? identifier : nil
    }
    for identifier in identifiers {
      owners.removeValue(forKey: identifier)
    }
    return identifiers
  }

  public mutating func removeAll() {
    owners.removeAll()
  }
}
