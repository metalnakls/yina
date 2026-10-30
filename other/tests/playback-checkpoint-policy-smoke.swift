import Foundation

@main struct CheckpointPolicySmoke {
  static func main() {
    precondition(PlaybackPositionCheckpoint.interval == 10)
    var policy = PlaybackPositionCheckpoint()
    precondition(policy.begin(position: .nan, now: 0, force: true) == nil)
    precondition(policy.begin(position: -1, now: 0, force: true) == nil)
    let initial = policy.begin(position: 10, now: 0, force: false)!
    precondition(policy.begin(position: 11, now: 1, force: false) == nil)
    precondition(!policy.finish(token: initial, success: true))
    precondition(policy.begin(position: 14, now: 9, force: false) == nil)
    let periodic = policy.begin(position: 15, now: 10, force: false)!
    precondition(policy.begin(position: 18, now: 11, force: true) == nil)
    precondition(policy.finish(token: periodic, success: true), "A pause/seek during a save must get another checkpoint")
    let seek = policy.begin(position: 18, now: 11, force: true)!
    precondition(!policy.finish(token: seek, success: true))
    precondition(policy.begin(position: 18, now: 100, force: false) == nil, "Pausing must not create periodic writes")
    let pause = policy.begin(position: 18, now: 100, force: true)!
    _ = policy.finish(token: pause, success: true)
    let old = policy.begin(position: 19, now: 110, force: false)!
    policy.reset()
    let current = policy.begin(position: 2, now: 111, force: false)!
    precondition(!policy.finish(token: old, success: false) && policy.failures == 0)
    precondition(policy.begin(position: 3, now: 121, force: false) == nil, "Old replies must not release the current save")
    _ = policy.finish(token: current, success: false)
    precondition(policy.failures == 1)
    precondition(policy.begin(position: 2, now: 121, force: false) != nil, "A failed checkpoint must be retryable")

    let player = PlayerCore()
    let client = player.mpv.asyncClient
    player.info.currentURL = URL(fileURLWithPath: "/generated.wav")
    player.cachedSavePositionOnQuit = false
    player.updateObservedPlayback(["time-pos": 10.0])
    precondition(client.commands.isEmpty, "Disabled resume must not write progress")
    player.cachedSavePositionOnQuit = true
    player.info.isSeeking = true
    player.updateObservedPlayback(["time-pos": 20.0])
    player.info.isSeeking = false
    player.info.justStartedFile = true
    player.updateObservedPlayback(["time-pos": 20.0])
    player.info.justStartedFile = false
    player.info.state = .starting
    player.updateObservedPlayback(["time-pos": 20.0])
    precondition(client.commands.isEmpty, "Loading and in-progress seeks must not overwrite a checkpoint")
    player.info.state = .paused
    player.updateObservedPlayback(["time-pos": 20.0])
    precondition(client.commands == [["write-watch-later-config"]])
    player.updateObservedPlayback(["time-pos": 21.0])
    player.checkpointPlaybackPosition(force: true)
    precondition(client.commands.count == 1)
    client.completions[0](0)
    precondition(client.commands.count == 2)
    client.completions[1](-1)
    let deadline = Date(timeIntervalSinceNow: 2)
    while client.commands.count < 3 && Date() < deadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    precondition(client.commands.count == 3, "A paused player must retry a rejected save without a UI timer")
    client.completions[2](0)
    player.updateObservedPlayback(["eof-reached": true])
    precondition(client.commands.last == ["delete-watch-later-config", "/generated.wav"])
    let count = client.commands.count
    player.checkpointPlaybackPosition(force: true)
    precondition(client.commands.count == count, "Completed files must be cleared once")
    player.updateObservedPlayback(["eof-reached": false, "time-pos": 5.0])
    precondition(client.commands.last == ["write-watch-later-config"], "Seeking back from EOF must save again")
    print("PASS: checkpoint cadence, idle pause, seek coalescing, failed-save retry, file generations, opt-out and EOF cleanup")
  }
}
