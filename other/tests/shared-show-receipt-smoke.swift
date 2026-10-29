// xcrun swiftc -parse-as-library yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift other/tests/shared-show-receipt-smoke.swift -o /tmp/yina-shared-receipt-smoke
import Foundation

@main
struct SharedShowReceiptSmoke {
  static func check(_ expression: @autoclosure () throws -> Bool, _ message: String = "Check failed") throws {
    let value = try expression()
    precondition(value, message)
  }
  static func main() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("yina-show-receipts-\(UUID())")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let store = try SharedShowStore(root: root)
    let showID = try store.enable().showID
    let requestID = UUID(), requestWriterID = UUID(), glassA = UUID(), glassB = UUID()
    func write(_ record: SharedShowStore.Receipt) throws {
      let folder = root.appendingPathComponent(".yina/receipts/\(record.receiptWriterID.uuidString.lowercased())")
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      try SharedShowStore.encoder().encode(record)
        .write(to: folder.appendingPathComponent("\(record.requestID.uuidString.lowercased()).json"), options: .atomic)
    }
    let accepted = SharedShowStore.Receipt(showID: showID, requestID: requestID,
      requestWriterID: requestWriterID, receiptWriterID: glassA, revision: 1,
      requestRevision: 2, updatedAt: Date(), outcome: .accepted, reason: nil)
    let failed = SharedShowStore.Receipt(showID: showID, requestID: requestID,
      requestWriterID: requestWriterID, receiptWriterID: glassB, revision: 1,
      requestRevision: 3, updatedAt: Date().addingTimeInterval(20), outcome: .failed, reason: "selectionFailed")
    try write(accepted)
    try write(failed)
    let records = try store.receipts(showID: showID, requestID: requestID)
    precondition(records.count == 2 && records.contains { $0.requestRevision == 2 } &&
                 records.contains { $0.requestRevision == 3 })
    precondition(records.filter { $0.requestWriterID == requestWriterID && $0.requestRevision == 3 }
      .allSatisfy { $0.outcome == .failed }, "Old acknowledgement answered a newer demand")
    try check(try store.receipts(showID: showID, requestID: UUID()).isEmpty)

    let invalid = SharedShowStore.Receipt(showID: showID, requestID: requestID,
      requestWriterID: requestWriterID, receiptWriterID: glassB, revision: 2,
      requestRevision: 3, updatedAt: Date(), outcome: .failed, reason: "private path /Users/name")
    precondition(!invalid.isValid)
    try write(invalid)
    do { _ = try store.receipts(showID: showID, requestID: requestID);
      fatalError("Malformed reason looked like an absent receipt") } catch {}
    let malformedFolder = root.appendingPathComponent(".yina/receipts/\(UUID().uuidString.lowercased())")
    try files.createDirectory(at: malformedFolder, withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: malformedFolder.appendingPathComponent("\(requestID.uuidString.lowercased()).json"))
    do { _ = try store.receipts(showID: showID, requestID: requestID);
      fatalError("Malformed receipt looked like an absent acknowledgement") } catch {}
    print("PASS: independent receipts, request revision matching, clock skew, fixed reason codes, and malformed fail-closed reads")
  }
}
