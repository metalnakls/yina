// Compile with AppEnvironment.swift and ShowFolder.swift; run with --clean-start.
import Cocoa

@main struct ShelfDismissSmoke {
  @MainActor static func main() {
    precondition(AppEnvironment.isCleanStart)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    defer { AppEnvironment.finishCleanStart() }
    let target = Target()
    let shows = (0..<3).map { index in
      ShowFolder(kind: .file, folderURL: URL(fileURLWithPath: "/tmp"),
                 primaryTitle: "Sample \(index)",
                 resumeURL: URL(fileURLWithPath: "/tmp/sample-\(index).mp4"),
                 secondaryTitle: "Sample", lastPlayedAt: Date(), position: 30,
                 duration: 100, thumbnailCacheName: "sample-\(index)")
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 220),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let shelf = ShowFolderShelfView(frame: window.contentView!.bounds)
    window.contentView = shelf // Keep the fixture offscreen; no history or media is opened.
    func reload(_ cards: [ShowFolder]) {
      shelf.reload(shows: cards, target: target, openAction: #selector(Target.action(_:)),
                   dismissAction: #selector(Target.action(_:)))
      shelf.layoutSubtreeIfNeeded()
    }
    func cardViews(_ root: NSView) -> [ShowFolderCardView] {
      (root as? ShowFolderCardView).map { [$0] } ?? root.subviews.flatMap(cardViews)
    }
    reload(shows)
    precondition(cardViews(shelf).count == 3)
    let survivor = cardViews(shelf).first { $0.show == shows[2] }!
    for index in 0..<2 {
      var completed = false
      shelf.dismissCard(for: shows[index]) { completed = true }
      reload(Array(shows.dropFirst(index + 1))) // Exercise a history refresh during dismissal.
      let deadline = Date().addingTimeInterval(3)
      while !completed && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(completed)
      reload(Array(shows.dropFirst(index + 1)))
      let cards = cardViews(shelf)
      precondition(cards.count == 2 - index)
      precondition(cards.contains { $0 === survivor }, "Surviving views must remain stable")
      precondition(cards.allSatisfy { abs($0.frame.width - ShowFolderCardView.size.width) < 1 })
    }
    print("PASS: multi-card dismissal preserves surviving views and widths across refreshes")
  }
  final class Target: NSObject {
    @objc func action(_ sender: Any) { }
  }
}
