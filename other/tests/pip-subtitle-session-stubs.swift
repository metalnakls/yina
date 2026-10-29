import Foundation

struct PiPSubtitleSuppression: Equatable {
  var primary = false
  var secondary = false
  var any: Bool { primary || secondary }
}

final class FakePanel {
  var reveals = 0
  var detaches = 0
  func reveal() { reveals += 1 }
  func detach() { detaches += 1 }
}

final class FakeMPV {
  struct Request {
    let primary: Bool
    let secondary: Bool
    let completion: (Bool) -> Void
  }
  var pending: [Request] = []
  func setSubtitlePresentationSuppressed(primary: Bool, secondary: Bool,
                                         completion: @escaping (Bool) -> Void) {
    pending.append(Request(primary: primary, secondary: secondary, completion: completion))
  }
  func complete(_ success: Bool) {
    precondition(!pending.isEmpty)
    pending.removeFirst().completion(success)
  }
}

final class FakePlayer { let mpv = FakeMPV() }

final class MainWindowController {
  let player = FakePlayer()
  var pipSubtitlePanel: FakePanel?
  var pipSubtitleDesired = PiPSubtitleSuppression()
  var pipSubtitleApplied = PiPSubtitleSuppression()
  var pipSubtitleAppliedKnown = true
  var pipSubtitleRequestInFlight = false
  var pipSubtitleGeneration: UInt64 = 0
  var pipSubtitleRestoreAttempts = 0
  var pipSubtitleRestoreRetry: DispatchWorkItem?
  var pipSubtitleRestoreRetryID: UInt64 = 0
  var pipSubtitleRestoreRetryReady = false
  func reconcile() { reconcilePiPSubtitlePresentation() }
  // PRODUCTION_RECONCILER
}
