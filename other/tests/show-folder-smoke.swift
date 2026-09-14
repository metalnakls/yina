// xcrun swiftc iina/ShowFolder.swift other/tests/show-folder-smoke.swift -o /tmp/iina-show-folder-smoke
// /tmp/iina-show-folder-smoke
import Foundation

@main struct ShowFolderSmoke {
  static func main() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let root = URL(fileURLWithPath: "/shows/Breaking Bad", isDirectory: true)
    func item(_ name: String, ageDays: Double, position: Double = 0, duration: Double = 100,
              mediaTitle: String? = nil) -> ShowFolderHistoryItem {
      ShowFolderHistoryItem(url: root.appendingPathComponent(name),
                            lastPlayedAt: now.addingTimeInterval(-ageDays * 86_400),
                            position: position, duration: duration,
                            mediaTitle: mediaTitle, thumbnailCacheName: name)
    }

    let shows = ShowFolder.make(from: [item("S01E01.mkv", ageDays: 4),
                                       item("S01E02.mkv", ageDays: 1, position: 50,
                                            mediaTitle: "S03E11 — Abiquiu")])
    precondition(shows.count == 1)
    precondition(shows[0].primaryTitle == "S03E11 — Abiquiu")
    precondition(shows[0].secondaryTitle == "Breaking Bad")
    precondition(shows[0].resumeURL.lastPathComponent == "S01E02.mkv")
    precondition(shows[0].progress == 0.5)

    let latestFile = ShowFolder.makeLatestFile(from: [item("Movie.mkv", ageDays: 1)],
                                               excludingFolderPaths: [])
    precondition(latestFile?.primaryTitle == "Movie")
    precondition(latestFile?.secondaryTitle == "Breaking Bad")

    precondition(ShowFolder.make(from: [item("Movie.mkv", ageDays: 1)]).isEmpty)
    precondition(ShowFolder.make(from: [item("S01E01.mkv", ageDays: 31),
                                        item("S01E02.mkv", ageDays: 32)], now: now).isEmpty)
    precondition(ShowFolder.make(from: [item("S01E01.mkv", ageDays: 29),
                                        item("S01E02.mkv", ageDays: 31)], now: now).count == 1)

    let shareRoot = URL(fileURLWithPath: "/Volumes/and", isDirectory: true)
    let shareRootItems = [
      ShowFolderHistoryItem(url: shareRoot.appendingPathComponent("Superbad.mkv"),
                            lastPlayedAt: now, position: 0, duration: 100,
                            mediaTitle: "Superbad", thumbnailCacheName: "superbad"),
      ShowFolderHistoryItem(url: shareRoot.appendingPathComponent("Other.mkv"),
                            lastPlayedAt: now.addingTimeInterval(-1), position: 0, duration: 100,
                            mediaTitle: "Other", thumbnailCacheName: "other"),
    ]
    precondition(ShowFolder.isVolumeRootPath("/Volumes/and"))
    precondition(ShowFolder.make(from: shareRootItems).isEmpty)

    let defaults = UserDefaults(suiteName: "ShowFolderSmoke-\(UUID().uuidString)")!
    let cachedPaths = Set([shows[0].folderURL.standardizedFileURL.path])
    ShowFolderSnapshotStore.save(cachedPaths, defaults: defaults)
    precondition(ShowFolderSnapshotStore.load(defaults: defaults) == cachedPaths)
    print("PASS: show folders group repeated files, resume personal latest progress, exclude films, and expire after 30 days.")
  }
}
