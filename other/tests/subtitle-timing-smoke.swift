// xcrun swiftc -parse-as-library yina/PlaybackSettingsView.swift other/tests/subtitle-timing-smoke.swift -o /tmp/yina-subtitle-timing-smoke
import SwiftUI

@main struct SubtitleTimingSmoke {
  @MainActor static func main() {
    let model = PlaybackSettingsModel(styles: [], overrides: [])
    var sent: [Double] = []
    model.perform = { if case .subtitleDelay(let delay) = $0 { sent.append(delay) } }
    var state = PlaybackSettingsSnapshot()
    state.hasMedia = true
    state.subtitleID = 1
    model.receive(state)
    precondition(model.subtitleTimingDescription == "Original timing")
    model.nudgeSubtitleDelay(-0.1)
    precondition(sent.last == -0.1 && model.subtitleTimingDescription.contains("earlier"),
                 "Earlier must advance the actual subtitle offset")
    model.nudgeSubtitleDelay(0.1)
    precondition(sent.last == 0 && model.subtitleTimingDescription == "Original timing")
    model.subtitleDelayBinding().wrappedValue = 1.26
    precondition(sent.last == 1.3 && model.subtitleTimingDescription.contains("later"),
                 "Slider must delay subtitles in tenths of a second")
    model.setEditing(true)
    model.receive(state)
    precondition(model.snapshot.subtitleDelay == 1.3, "Delayed playback notification moved the dragged thumb")
    model.setEditing(false)
    state.subtitleDelay = -8.2
    model.receive(state)
    precondition(model.snapshot.subtitleDelay == -8.2 && model.subtitleTimingRange == -9...9,
                 "External keyboard changes must update the control with zero still centered")
    model.setSubtitleDelay(0)
    precondition(sent.last == 0 && model.subtitleTimingRange == -5...5,
                 "Reset must restore subtitle timing, not audio delay")
    let count = sent.count
    model.setSubtitleDelay(.nan)
    precondition(sent.count == count, "Invalid offsets must not reach the player")
    model.setEditing(true)
    model.receive(PlaybackSettingsSnapshot())
    precondition(!model.snapshot.hasMedia && model.snapshot.subtitleDelay == 0)
    print("PASS: earlier/later command direction, slider rounding, reset, delayed snapshots, external changes, range, and media reset")
  }
}
