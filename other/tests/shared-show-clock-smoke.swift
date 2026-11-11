import Foundation

@main struct SharedShowClockSmoke {
  static func main() {
    var clock = SharedShowClock()
    clock.seed(hostTime: 102, localReceive: 100.05)
    precondition(!clock.calibrated && clock.uncertainty == nil, "Seed is only provisional")

    // Host clock is two seconds ahead; 40 ms each direction.
    clock.observe(clientSend: 10, hostReceive: 12.04,
                  hostSend: 12.05, clientReceive: 10.09)
    precondition(clock.calibrated)
    precondition(abs((clock.offset ?? 0) - 2) < 0.000001)
    precondition(abs((clock.uncertainty ?? 0) - 0.04) < 0.000001)
    precondition(abs((clock.hostTime(at: 20) ?? 0) - 22) < 0.000001)

    // A delayed, asymmetric sample must not pull playback to a false offset.
    clock.observe(clientSend: 20, hostReceive: 22.5,
                  hostSend: 22.51, clientReceive: 20.55)
    precondition(abs((clock.offset ?? 0) - 2) < 0.000001)
    clock.observe(clientSend: 30, hostReceive: 32.01,
                  hostSend: 32.02, clientReceive: 30.03)
    precondition(abs((clock.offset ?? 0) - 2) < 0.000001)
    clock.observe(clientSend: 40, hostReceive: 43,
                  hostSend: 42.9, clientReceive: 40.01)
    precondition(abs((clock.offset ?? 0) - 2) < 0.000001, "Invalid sample changed clock")

    var nearBest = SharedShowClock()
    nearBest.observe(clientSend: 0, hostReceive: 2.001,
                     hostSend: 2.002, clientReceive: 0.003)
    nearBest.observe(clientSend: 1, hostReceive: 3.0028,
                     hostSend: 3.0038, clientReceive: 1.0048)
    precondition((nearBest.uncertainty ?? 0) >= 0.0019 - 0.000001,
                 "Near-best asymmetric RTT was treated as more precise than it is")
    for index in 0..<20 {
      let t = Double(index + 10)
      nearBest.observe(clientSend: t, hostReceive: t + 2.04,
                       hostSend: t + 2.05, clientReceive: t + 0.09)
    }
    precondition(abs((nearBest.offset ?? 0) - 2) < 0.000001,
                 "Sample-window rollover changed stable offset")
    print("PASS: provisional seed, four-timestamp calibration, jitter, asymmetric uncertainty, rollover")
  }
}
