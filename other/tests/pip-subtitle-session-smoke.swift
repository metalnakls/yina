import Foundation

@main struct PiPSubtitleSessionSmoke {
  static func main() {
    let controller = MainWindowController()
    let mpv = controller.player.mpv
    controller.reconcile()
    precondition(mpv.pending.isEmpty, "No subtitles must not submit suppression")

    // Entry, close, then reopen before mpv answers the first request.
    controller.pipSubtitlePanel = FakePanel()
    controller.pipSubtitleDesired.primary = true
    controller.reconcile()
    precondition(mpv.pending.count == 1 && mpv.pending[0].primary)
    controller.pipSubtitleGeneration += 1
    controller.pipSubtitlePanel = nil
    controller.pipSubtitleDesired.primary = false
    controller.reconcile()
    controller.pipSubtitleGeneration += 1
    let reopenedPanel = FakePanel()
    controller.pipSubtitlePanel = reopenedPanel
    controller.pipSubtitleDesired.primary = true
    controller.reconcile()
    precondition(mpv.pending.count == 1, "Rapid requests must coalesce")
    mpv.complete(true)
    precondition(reopenedPanel.reveals == 1, "A confirmed old reply must reveal the new host")

    // Closing again requests restoration; a new entry waits for that reply.
    controller.pipSubtitleDesired.primary = false
    controller.reconcile()
    precondition(mpv.pending.count == 1 && !mpv.pending[0].primary)
    controller.pipSubtitleGeneration += 1
    controller.pipSubtitleDesired.primary = true
    controller.reconcile()
    mpv.complete(true)
    precondition(mpv.pending.count == 1 && mpv.pending[0].primary)
    mpv.complete(true)
    precondition(reopenedPanel.reveals == 2)

    // A current failed suppression must leave native mpv rendering restored.
    controller.pipSubtitleDesired.secondary = true
    controller.reconcile()
    mpv.complete(false)
    precondition(reopenedPanel.detaches == 1)
    precondition(mpv.pending.count == 1 && !mpv.pending[0].primary && !mpv.pending[0].secondary)
    mpv.complete(true)
    precondition(!controller.pipSubtitleDesired.any)

    // A failed restore must retry, then stop after a bounded number of tries.
    let failedRestore = MainWindowController()
    let failingMPV = failedRestore.player.mpv
    failedRestore.pipSubtitleDesired.primary = true
    failedRestore.reconcile()
    failingMPV.complete(true)
    failedRestore.pipSubtitleDesired.primary = false
    failedRestore.reconcile()
    failingMPV.complete(false)
    for attempt in 1...3 {
      let deadline = Date(timeIntervalSinceNow: 1.5)
      while failingMPV.pending.isEmpty && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
      }
      precondition(failingMPV.pending.count == 1 && !failingMPV.pending[0].primary,
                   "Restore retry \(attempt) was not submitted")
      failingMPV.complete(false)
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
    precondition(failingMPV.pending.isEmpty && failedRestore.pipSubtitleRestoreAttempts == 3,
                 "Failed restore retried without a bound")

    // A fresh desired presentation cancels a queued restore retry.
    let replaced = MainWindowController()
    let replacementMPV = replaced.player.mpv
    replaced.pipSubtitleDesired.primary = true
    replaced.reconcile()
    replacementMPV.complete(true)
    replaced.pipSubtitleDesired.primary = false
    replaced.reconcile()
    replacementMPV.complete(false)
    replaced.pipSubtitleGeneration += 1
    replaced.pipSubtitleDesired.primary = true
    replaced.reconcile()
    precondition(replacementMPV.pending.count == 1 && replacementMPV.pending[0].primary)
    replacementMPV.complete(true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(replacementMPV.pending.isEmpty, "Canceled restore retry submitted after reentry")
    print("PASS: no-subtitle, rapid close/reopen, ordered restoration, failure fallback, bounded restore retry and cancellation")
  }
}
