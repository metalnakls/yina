// xcrun swiftc iina/ShowFolder.swift other/tests/show-folder-smoke.swift -o /tmp/iina-show-folder-smoke
// /tmp/iina-show-folder-smoke
import Foundation

@main struct ShowFolderSmoke {
  static func main() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let root = URL(fileURLWithPath: "/shows/Breaking Bad", isDirectory: true)
    func item(_ name: String, ageDays: Double, position: Double = 0, duration: Double = 100) -> ShowFolderHistoryItem {
      ShowFolderHistoryItem(url: root.appendingPathComponent(name),
                            lastPlayedAt: now.addingTimeInterval(-ageDays * 86_400),
                            position: position, duration: duration,
                            displayTitle: name, thumbnailCacheName: name)
    }

    let shows = ShowFolder.make(from: [item("S01E01.mkv", ageDays: 4),
                                       item("S01E02.mkv", ageDays: 1, position: 50)])
    precondition(shows.count == 1)
    precondition(shows[0].title == "Breaking Bad")
    precondition(shows[0].resumeURL.lastPathComponent == "S01E02.mkv")
    precondition(shows[0].progress == 0.5)

    precondition(ShowFolder.make(from: [item("Movie.mkv", ageDays: 1)]).isEmpty)
    precondition(ShowFolder.make(from: [item("S01E01.mkv", ageDays: 31),
                                        item("S01E02.mkv", ageDays: 32)], now: now).isEmpty)
    precondition(ShowFolder.make(from: [item("S01E01.mkv", ageDays: 29),
                                        item("S01E02.mkv", ageDays: 31)], now: now).count == 1)
    print("PASS: show folders group repeated files, resume personal latest progress, exclude films, and expire after 30 days.")
  }
}
