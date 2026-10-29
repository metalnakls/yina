@main struct PiPTransitionSmoke {
  static func main() {
    let fullscreen = PiPEntryPlan.make(isFullscreen: true, isMiniaturized: false,
                                      preferredAction: .hide, pausePreference: false)
    precondition(fullscreen.windowAction == .doNothing && !fullscreen.pausePlayback)
    let fullscreenMini = PiPEntryPlan.make(isFullscreen: true, isMiniaturized: true,
                                          preferredAction: .minimize, pausePreference: true)
    precondition(fullscreenMini.windowAction == .doNothing && fullscreenMini.pausePlayback)
    let hidden = PiPEntryPlan.make(isFullscreen: false, isMiniaturized: false,
                                  preferredAction: .hide, pausePreference: false)
    precondition(hidden.windowAction == .hide && !hidden.pausePlayback)
    let minimized = PiPEntryPlan.make(isFullscreen: false, isMiniaturized: false,
                                     preferredAction: .minimize, pausePreference: true)
    precondition(minimized.windowAction == .minimize && minimized.pausePlayback)
    let alreadyMiniaturized = PiPEntryPlan.make(isFullscreen: false, isMiniaturized: true,
                                                preferredAction: .hide, pausePreference: false)
    precondition(alreadyMiniaturized.windowAction == .doNothing)
    print("PASS: full screen Space preserved; windowed hide/minimize and pause preferences respected")
  }
}
