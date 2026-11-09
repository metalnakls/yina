import Foundation

/// Owns PiP intent and native-transition lifetime. AppKit effects stay in the
/// window controller; callbacks must identify the session that produced them.
struct PiPTransitionState {
  enum Phase: Equatable { case windowed, waitingForVideo, entering, active, exiting }

  private(set) var phase: Phase = .windowed
  private(set) var generation: UInt64 = 0
  private(set) var restoresWindow = true
  private var pendingEntry = false
  private(set) var pendingExit: Bool?

  var hasPendingEntry: Bool { pendingEntry }
  var hasSession: Bool { phase == .entering || phase == .active || phase == .exiting }
  var sessionID: UInt64? { hasSession ? generation : nil }
  var ownsPresentation: Bool { phase != .windowed }

  /// A URL/CLI open requests PiP for the new media even if an old session is
  /// still attached. Preserve that intent through its asynchronous close.
  mutating func requestEntryForMedia() {
    pendingEntry = true
    if phase == .windowed { phase = .waitingForVideo }
  }

  mutating func waitForVideo() {
    guard phase == .windowed || phase == .waitingForVideo || phase == .exiting else { return }
    pendingEntry = true
    if phase == .windowed { phase = .waitingForVideo }
  }

  mutating func cancelPendingEntry() {
    pendingEntry = false
    if phase == .waitingForVideo { phase = .windowed }
  }

  mutating func beginEntry() -> UInt64? {
    guard phase == .windowed || phase == .waitingForVideo else { return nil }
    generation &+= 1
    pendingEntry = false
    phase = .entering
    pendingExit = nil
    restoresWindow = true
    return generation
  }

  func accepts(_ session: UInt64) -> Bool { sessionID == session }

  @discardableResult
  mutating func attached(_ session: UInt64) -> Bool {
    guard accepts(session), phase == .entering else { return false }
    phase = .active
    return true
  }

  /// AppKit may still be moving the view when the user asks to return.
  /// Dismissing before attachment can be ignored by the native controller.
  mutating func deferExitUntilAttached(restoringWindow: Bool) -> Bool {
    guard phase == .entering else { return false }
    pendingExit = restoringWindow
    return true
  }

  mutating func takePendingExit(_ session: UInt64) -> Bool? {
    guard accepts(session), phase == .active else { return nil }
    defer { pendingExit = nil }
    return pendingExit
  }

  @discardableResult
  mutating func beginExit(_ session: UInt64, restoringWindow: Bool) -> Bool {
    guard accepts(session), phase == .entering || phase == .active else { return false }
    pendingExit = nil
    restoresWindow = restoringWindow
    phase = .exiting
    return true
  }

  mutating func preventWindowRestore(_ session: UInt64) {
    guard accepts(session) else { return }
    restoresWindow = false
  }

  /// The system can close without a preceding will-close callback. Complete it
  /// once, and reject duplicate or previous-session callbacks before UI work.
  mutating func completeExit(_ session: UInt64) -> Bool? {
    guard accepts(session) else { return nil }
    let restore = (pendingExit ?? restoresWindow) && !pendingEntry
    pendingExit = nil
    phase = pendingEntry ? .waitingForVideo : .windowed
    restoresWindow = true
    return restore
  }
}
