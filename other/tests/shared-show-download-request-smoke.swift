// xcrun swiftc -parse-as-library yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift yina/SharedShowDownloadRequest.swift other/tests/shared-show-download-request-smoke.swift -o /tmp/yina-request-smoke
import Foundation

@main
struct SharedShowDownloadRequestSmoke {
  static func main() {
    let showID = UUID(), requestID = UUID(), writerID = UUID(), participantID = UUID()
    let first = SharedShowStore.Demand(showID: showID, requestID: requestID,
      participantID: participantID, writerID: writerID, revision: 4, updatedAt: Date(),
      relativePath: "Season/Episode.mkv", hashString: String(repeating: "a", count: 40),
      fileIndex: 2, cancelled: false)
    func receipt(requestRevision: UInt64, writer: UUID = writerID,
                 outcome: SharedShowStore.Receipt.Outcome = .accepted,
                 reason: String? = nil) -> SharedShowStore.Receipt {
      .init(showID: showID, requestID: requestID, requestWriterID: writer,
            receiptWriterID: UUID(), revision: 1, requestRevision: requestRevision,
            updatedAt: Date().addingTimeInterval(30), outcome: outcome, reason: reason)
    }
    var state = SharedShowDownloadRequest(record: first)
    precondition(!state.canRetry && state.canWithdraw && !state.shouldPoll,
                 "A pending write cannot be withdrawn behind a slow share")
    state.publicationFinished(for: 4, succeeded: true)
    precondition(state.shouldPoll && state.canWithdraw && !state.canRetry)
    state.observe([], for: 4)
    precondition(state.phase == .waiting, "Absence must not resend or infer failure")
    state.observe([receipt(requestRevision: 3), receipt(requestRevision: 4, writer: UUID())], for: 4)
    precondition(state.phase == .waiting, "Stale or foreign receipt answered demand")
    state.receiptReadFailed(for: 4)
    precondition(state.phase == .statusUnavailable && state.canRetry && state.canWithdraw)
    state.observe([receipt(requestRevision: 4, outcome: .failed, reason: "selectionFailed")], for: 4)
    precondition(state.phase == .failed("selectionFailed") && state.canRetry && !state.canWithdraw)

    let retried = state.advance(revision: 7, cancelled: false)
    precondition(retried.requestID == requestID && retried.revision == 7 && !retried.cancelled)
    state.publicationFinished(for: 4, succeeded: true)
    precondition(state.phase == .saving, "Old publish callback replaced retry state")
    state.publicationFinished(for: 7, succeeded: true)
    state.observe([receipt(requestRevision: 4)], for: 7)
    precondition(state.phase == .waiting, "Old accepted receipt acknowledged retry")
    state.observe([receipt(requestRevision: 7, outcome: .failed, reason: "priorityFailed"),
                   receipt(requestRevision: 7)], for: 7)
    precondition(state.phase == .accepted && !state.canRetry && !state.canWithdraw,
                 "Accepted request was mistaken for a cancellable pending download")

    var offline = SharedShowDownloadRequest(record: first)
    offline.publicationFinished(for: 4, succeeded: false)
    precondition(offline.phase == .saveFailed && offline.canRetry && !offline.shouldPoll)
    let retry = offline.advance(revision: 5, cancelled: false)
    precondition(retry.requestID == requestID)
    offline.publicationFinished(for: 5, succeeded: true)
    let withdrawn = offline.advance(revision: 6, cancelled: true)
    precondition(withdrawn.requestID == requestID && withdrawn.cancelled && withdrawn.revision == 6)
    offline.publicationFinished(for: 6, succeeded: true)
    precondition(offline.phase == .withdrawn && !offline.shouldPoll && offline.canRetry)
    precondition(offline.status.contains("may continue"), "Withdraw implied stopping Glass")
    var blocked = SharedShowDownloadRequest(record: first)
    let queuedWithdrawal = blocked.advance(revision: 5, cancelled: true)
    blocked.publicationFinished(for: 4, succeeded: true)
    precondition(blocked.phase == .withdrawing && queuedWithdrawal.revision == 5,
                 "Old blocked write callback replaced queued withdrawal")
    blocked.publicationFinished(for: 5, succeeded: true)
    precondition(blocked.phase == .withdrawn)
    var expired = SharedShowDownloadRequest(record: first)
    expired.publicationFinished(for: 4, succeeded: true)
    expired.expireIfNeeded(at: first.updatedAt.addingTimeInterval(15 * 60 + 1))
    precondition(expired.phase == .expired && expired.canRetry && expired.canWithdraw && !expired.shouldPoll)
    expired.observe([receipt(requestRevision: 4)], for: 4)
    precondition(expired.phase == .expired, "Expired request silently resumed polling or accepted late receipt")
    print("PASS: missing/foreign/stale receipts, explicit retry, clock skew, accepted state, offline save, and newer withdrawal")
  }
}
