import Foundation

@main struct SubtitlePresentationSmoke {
  static func main() {
    let state = SubtitlePresentationState()
    let primary = "sub-visibility"
    let secondary = "secondary-sub-visibility"
    precondition(state.update(primary, suppressed: true, desired: true) == false)
    precondition(!state.acceptsObservation(false, for: primary))
    precondition(!state.renderedValue(true, for: primary))
    // Turning the primary off while it is outside the picture must survive exit.
    precondition(!state.renderedValue(false, for: primary))
    precondition(state.update(primary, suppressed: false, desired: false) == false)
    precondition(!state.acceptsObservation(true, for: primary))
    precondition(state.acceptsObservation(false, for: primary))
    // Secondary choices remain independent; late suppression events cannot undo restoration.
    precondition(state.update(secondary, suppressed: true, desired: true) == false)
    precondition(state.update(secondary, suppressed: false, desired: true) == true)
    precondition(!state.acceptsObservation(false, for: secondary))
    precondition(state.acceptsObservation(true, for: secondary))
    for _ in 0..<100 {
      _ = state.update(primary, suppressed: true, desired: true)
      _ = state.update(primary, suppressed: false, desired: true)
      _ = state.update(primary, suppressed: true, desired: true)
      precondition(!state.acceptsObservation(true, for: primary))
      _ = state.update(primary, suppressed: false, desired: false)
      precondition(!state.acceptsObservation(true, for: primary))
      precondition(state.acceptsObservation(false, for: primary))
    }
    precondition(state.renderedValue(true, for: "mute"))
    print("PASS: PiP visibility restoration, user changes while detached, independent tracks, repeated transitions and late observations")
  }
}
