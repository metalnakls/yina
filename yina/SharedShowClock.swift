import Foundation

/// NTP-style four-timestamp estimator for a monotonic host clock. A state
/// arrival may seed a provisional offset, but only a round trip calibrates it.
struct SharedShowClock {
  private(set) var offset: Double?
  private(set) var uncertainty: Double?
  private(set) var calibrated = false
  private var samples: [(offset: Double, rtt: Double)] = []

  mutating func seed(hostTime: Double, localReceive: Double) {
    guard offset == nil, hostTime.isFinite, localReceive.isFinite else { return }
    offset = hostTime - localReceive
    uncertainty = nil
  }

  mutating func observe(clientSend: Double, hostReceive: Double,
                        hostSend: Double, clientReceive: Double) {
    let rtt = (clientReceive - clientSend) - (hostSend - hostReceive)
    guard [clientSend, hostReceive, hostSend, clientReceive, rtt].allSatisfy(\.isFinite),
          rtt >= 0, rtt <= 5, hostSend >= hostReceive, clientReceive >= clientSend else { return }
    let estimate = ((hostReceive - clientSend) + (hostSend - clientReceive)) / 2
    samples.append((estimate, rtt))
    if samples.count > 16 { samples.removeFirst(samples.count - 16) }
    guard let minimumRTT = samples.map(\.rtt).min() else { return }
    let lowLatency = samples.filter { $0.rtt <= minimumRTT + 0.002 }
    let orderedOffsets = lowLatency.map(\.offset).sorted()
    let center = orderedOffsets[orderedOffsets.count / 2]
    offset = center
    uncertainty = lowLatency.map { $0.rtt / 2 + abs($0.offset - center) }.max()
    calibrated = true
  }

  func hostTime(at localTime: Double) -> Double? { offset.map { localTime + $0 } }
}
