import Foundation

@main struct PiPTransitionStateSmoke {
  static func main() {
    var state = PiPTransitionState()
    state.waitForVideo()
    precondition(state.hasPendingEntry && state.ownsPresentation && !state.hasSession)
    state.cancelPendingEntry()
    precondition(state.phase == .windowed)
    state.waitForVideo()
    let first = state.beginEntry()!
    precondition(!state.hasPendingEntry && state.phase == .entering)
    precondition(state.beginEntry() == nil)
    precondition(!state.attached(first + 1))
    precondition(state.attached(first) && !state.attached(first))
    state.preventWindowRestore(first)
    precondition(state.beginExit(first, restoringWindow: state.restoresWindow))
    precondition(!state.beginExit(first, restoringWindow: true))
    precondition(state.beginEntry() == nil)
    precondition(state.completeExit(first) == false)
    precondition(state.completeExit(first) == nil)
    let second = state.beginEntry()!
    precondition(second != first)
    precondition(!state.accepts(first) && state.accepts(second))
    precondition(state.completeExit(first) == nil && state.phase == .entering)
    // Close while entry is unfinished, including missing will-close.
    precondition(state.completeExit(second) == true)
    let third = state.beginEntry()!
    precondition(state.beginExit(third, restoringWindow: true))
    state.preventWindowRestore(third)
    precondition(state.completeExit(third) == false)
    precondition(!state.hasSession && !state.ownsPresentation)
    let fourth = state.beginEntry()!
    precondition(state.beginExit(fourth, restoringWindow: true))
    state.waitForVideo() // A new request arrives while native dismissal finishes.
    precondition(state.hasPendingEntry && state.phase == .exiting)
    precondition(state.completeExit(fourth) == false && state.phase == .waitingForVideo)
    let fifth = state.beginEntry()!
    precondition(state.completeExit(fourth) == nil && state.accepts(fifth))
    precondition(state.completeExit(fifth) == true)
    let sixth = state.beginEntry()!
    state.attached(sixth)
    state.requestEntryForMedia()
    precondition(state.phase == .active && state.hasPendingEntry)
    state.beginExit(sixth, restoringWindow: false)
    precondition(state.completeExit(sixth) == false && state.hasPendingEntry)
    state.cancelPendingEntry() // Replacement is canceled or fails.
    precondition(state.phase == .windowed)
    let earlyClose = state.beginEntry()!
    precondition(state.deferExitUntilAttached(restoringWindow: true))
    precondition(state.phase == .entering && state.pendingExit == true)
    precondition(state.takePendingExit(earlyClose) == nil)
    precondition(state.attached(earlyClose))
    precondition(state.takePendingExit(earlyClose + 1) == nil)
    precondition(state.takePendingExit(earlyClose) == true)
    precondition(state.takePendingExit(earlyClose) == nil)
    precondition(state.beginExit(earlyClose, restoringWindow: true))
    precondition(state.completeExit(earlyClose) == true)
    let nonRestoring = state.beginEntry()!
    precondition(state.deferExitUntilAttached(restoringWindow: false))
    precondition(state.completeExit(nonRestoring) == false)
    precondition(state.pendingExit == nil)
    print("PASS: deferred entry, cancellation, session identity, attachment, close during entry, duplicate callbacks, reentry and restoration policy")
  }
}
