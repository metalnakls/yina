import Foundation

/// UI state for one explicitly submitted Glass demand. The request ID stays
/// stable across retry/withdraw; each action publishes a newer revision.
struct SharedShowDownloadRequest {
  enum Phase: Equatable {
    case saving, waiting, accepted, failed(String), statusUnavailable, expired
    case saveFailed, withdrawing, withdrawFailed, withdrawn
  }

  private(set) var record: SharedShowStore.Demand
  private(set) var phase: Phase = .saving

  init(record: SharedShowStore.Demand) { self.record = record }

  var canRetry: Bool {
    switch phase {
    case .failed, .saveFailed, .statusUnavailable, .expired, .withdrawn: return true
    default: return false
    }
  }

  var canWithdraw: Bool {
    guard !record.cancelled else { return phase == .withdrawFailed }
    return phase == .saving || phase == .waiting || phase == .statusUnavailable || phase == .expired
  }

  var shouldPoll: Bool {
    !record.cancelled && (phase == .waiting || phase == .statusUnavailable)
  }

  var status: String {
    switch phase {
    case .saving: return "Saving download request…"
    case .waiting: return "Request saved; waiting for Glass"
    case .accepted: return "Glass accepted request; waiting for media"
    case .failed(let reason):
      switch reason {
      case "selectionFailed": return "Glass could not select this file. Retry the request."
      case "priorityFailed": return "Glass could not prioritize this file. Retry the request."
      default: return "Glass could not start this download. Retry the request."
      }
    case .statusUnavailable: return "Request saved; Glass status unavailable"
    case .expired: return "No recent Glass response. Retry or withdraw explicitly."
    case .saveFailed: return "Couldn’t save the request. Retry when the folder is available."
    case .withdrawing: return "Withdrawing request…"
    case .withdrawFailed: return "Couldn’t withdraw the request. Try again."
    case .withdrawn: return "Request withdrawn. An active download may continue in Glass."
    }
  }

  mutating func advance(revision: UInt64, cancelled: Bool, at date: Date = Date()) -> SharedShowStore.Demand {
    precondition(revision > record.revision)
    let next = SharedShowStore.Demand(showID: record.showID, requestID: record.requestID,
      participantID: record.participantID, writerID: record.writerID, revision: revision,
      updatedAt: date, relativePath: record.relativePath, hashString: record.hashString,
      fileIndex: record.fileIndex, cancelled: cancelled)
    record = next
    phase = cancelled ? .withdrawing : .saving
    return next
  }

  mutating func publicationFinished(for revision: UInt64, succeeded: Bool) {
    guard record.revision == revision else { return }
    if succeeded { phase = record.cancelled ? .withdrawn : .waiting }
    else { phase = record.cancelled ? .withdrawFailed : .saveFailed }
  }

  mutating func receiptReadFailed(for revision: UInt64) {
    guard record.revision == revision, shouldPoll else { return }
    phase = .statusUnavailable
  }

  mutating func expireIfNeeded(at now: Date = Date()) {
    guard shouldPoll, now.timeIntervalSince(record.updatedAt) >= ShowEpisodeIndexReader.freshnessLimit else { return }
    phase = .expired
  }

  /// Only the current demand revision and writer can acknowledge this action.
  /// Acceptance wins if independent Glass writers report conflicting results.
  mutating func observe(_ receipts: [SharedShowStore.Receipt], for revision: UInt64) {
    guard record.revision == revision, shouldPoll else { return }
    let matching = receipts.filter {
      $0.isValid && $0.showID == record.showID && $0.requestID == record.requestID &&
      $0.requestWriterID == record.writerID && $0.requestRevision == record.revision
    }
    if matching.contains(where: { $0.outcome == .accepted }) { phase = .accepted }
    else if let failure = matching.first(where: { $0.outcome == .failed }) {
      phase = .failed(failure.reason ?? "startFailed")
    } else if matching.contains(where: { $0.outcome == .cancelled }) {
      phase = .withdrawn
    } else if phase == .statusUnavailable { phase = .waiting }
  }
}
