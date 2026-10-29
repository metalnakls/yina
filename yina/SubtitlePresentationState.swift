import Foundation

/// Separates the user's visibility choice from temporary PiP renderer suppression.
/// Accessed by property writers and the main-thread event delivery path.
final class SubtitlePresentationState {
  private let lock = NSLock()
  private var suppressed: Set<String> = []
  private var restoring: [String: Bool] = [:]

  func update(_ name: String, suppressed newValue: Bool, desired: Bool) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    guard suppressed.contains(name) != newValue else { return nil }
    if newValue {
      suppressed.insert(name)
      restoring.removeValue(forKey: name)
      return false
    }
    suppressed.remove(name)
    restoring[name] = desired
    return desired
  }

  func renderedValue(_ desired: Bool, for name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if suppressed.contains(name) { return false }
    if restoring[name] != nil { restoring[name] = desired }
    return desired
  }

  func acceptsObservation(_ value: Bool, for name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !suppressed.contains(name) else { return false }
    if let expected = restoring[name] {
      guard value == expected else { return false }
      restoring.removeValue(forKey: name)
    }
    return true
  }

  func isSuppressed(_ name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return suppressed.contains(name)
  }
}
