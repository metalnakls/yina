// xcrun swiftc iina/ShowFolder.swift other/tests/show-folder-smoke.swift -o /tmp/iina-show-folder-smoke
// /tmp/iina-show-folder-smoke
import Foundation

@main struct ShowFolderSmoke {
  static func main() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let root = URL(fileURLWithPath: "/shows/Breaking Bad", isDirectory: true)
    func item(_ name: String, ageDays: Double, position: Double = 0,
              duration: Double = 100) -> ShowFolderHistoryItem {
      ShowFolderHistoryItem(url: root.appendingPathComponent(name),
                            lastPlayedAt: now.addingTimeInterval(-ageDays * 86_400),
                            position: position, duration: duration,
                            thumbnailCacheName: name)
    }

    let shows = ShowFolder.make(from: [item("S01E01.mkv", ageDays: 4),
                                       item("S03E11.mkv", ageDays: 1, position: 50)])
    precondition(ShowFolder.groupedFolderPaths(
      from: [item("S01E01.mkv", ageDays: 4), item("S03E11.mkv", ageDays: 1)],
      volumeRootPaths: []).contains(root.standardizedFileURL.path))
    precondition(shows.count == 1)
    precondition(shows[0].primaryTitle == "Breaking Bad")
    precondition(shows[0].secondaryTitle == "S03E11")
    precondition(shows[0].resumeActionLabel == "Resume S03E11")
    precondition(shows[0].resumeActionHelp ==
      "Opens S03E11 from Breaking Bad at your saved position")
    precondition(shows[0].resumeURL.lastPathComponent == "S03E11.mkv")
    precondition(shows[0].progress == 0.5)

    let latestFile = ShowFolder.makeLatestFile(from: [item("Movie.mkv", ageDays: 1)],
                                               excludingFolderPaths: [])
    precondition(latestFile?.primaryTitle == "Movie")
    precondition(latestFile?.secondaryTitle == "Breaking Bad")

    let fargoRoot = URL(fileURLWithPath: "/Volumes/and/Fargo", isDirectory: true)
    let fargoItems = [
      ShowFolderHistoryItem(url: fargoRoot.appendingPathComponent("S01E10.mkv"),
                            lastPlayedAt: now.addingTimeInterval(-1), position: 0, duration: 100,
                            thumbnailCacheName: "fargo-old"),
      ShowFolderHistoryItem(url: fargoRoot.appendingPathComponent("S02E01.mkv"),
                            lastPlayedAt: now, position: 0, duration: 100,
                            thumbnailCacheName: "fargo-latest"),
    ]
    let fargo = ShowFolder.make(from: fargoItems,
                                folderPaths: [fargoRoot.standardizedFileURL.path],
                                now: now,
                                volumeRootPaths: [])
    precondition(fargo.count == 1)
    precondition(fargo[0].primaryTitle == "Fargo")
    precondition(fargo[0].secondaryTitle == "S02E01")

    let moviesRoot = URL(fileURLWithPath: "/Users/wsb/Movies/Actual Movies", isDirectory: true)
    let movieItems = [
      ShowFolderHistoryItem(url: moviesRoot.appendingPathComponent("Another Movie.mkv"),
                            lastPlayedAt: now.addingTimeInterval(-1), position: 0, duration: 100,
                            thumbnailCacheName: "movie-old"),
      ShowFolderHistoryItem(url: moviesRoot.appendingPathComponent("Apartment.mkv"),
                            lastPlayedAt: now, position: 0, duration: 100,
                            thumbnailCacheName: "apartment"),
    ]
    let movieFolderPaths = ShowFolder.groupedFolderPaths(from: movieItems, volumeRootPaths: [])
    precondition(!movieFolderPaths.contains(moviesRoot.standardizedFileURL.path))
    precondition(ShowFolder.make(from: movieItems, now: now, volumeRootPaths: []).isEmpty)
    let movie = ShowFolder.makeLatestFile(from: movieItems,
                                          excludingFolderPaths: movieFolderPaths,
                                          now: now)
    precondition(movie?.primaryTitle == "Apartment")
    precondition(movie?.secondaryTitle == "Actual Movies")
    precondition(movie?.resumeURL.lastPathComponent == "Apartment.mkv")

    precondition(ShowFolder.isEpisodeFileURL(URL(fileURLWithPath: "Fargo.S02E01.mkv")))
    precondition(ShowFolder.isEpisodeFileURL(URL(fileURLWithPath: "Show S01.E02.mkv")))
    precondition(ShowFolder.isEpisodeFileURL(URL(fileURLWithPath: "Show 1x02.mkv")))
    precondition(ShowFolder.isEpisodeFileURL(URL(fileURLWithPath: "Show Episode 02.mkv")))
    precondition(!ShowFolder.isEpisodeFileURL(URL(fileURLWithPath: "Apartment.mkv")))

    let mixedRoot = URL(fileURLWithPath: "/shows/Mixed", isDirectory: true)
    let mixedItems = [
      ShowFolderHistoryItem(url: mixedRoot.appendingPathComponent("S01E01.mkv"),
                            lastPlayedAt: now, position: 0, duration: 100,
                            thumbnailCacheName: "episode"),
      ShowFolderHistoryItem(url: mixedRoot.appendingPathComponent("Movie.mkv"),
                            lastPlayedAt: now, position: 0, duration: 100,
                            thumbnailCacheName: "movie"),
    ]
    precondition(!ShowFolder.groupedFolderPaths(from: mixedItems, volumeRootPaths: [])
      .contains(mixedRoot.standardizedFileURL.path))

    precondition(ShowFolder.make(from: [item("Movie.mkv", ageDays: 1)]).isEmpty)
    precondition(ShowFolder.make(from: [item("S01E01.mkv", ageDays: 31),
                                        item("S01E02.mkv", ageDays: 32)], now: now).isEmpty)
    precondition(ShowFolder.make(from: [item("S01E01.mkv", ageDays: 29),
                                        item("S01E02.mkv", ageDays: 31)], now: now).count == 1)

    let shareRoot = URL(fileURLWithPath: "/Volumes/and", isDirectory: true)
    let shareRootItems = [
      ShowFolderHistoryItem(url: shareRoot.appendingPathComponent("Superbad.mkv"),
                            lastPlayedAt: now, position: 0, duration: 100,
                            thumbnailCacheName: "superbad"),
      ShowFolderHistoryItem(url: shareRoot.appendingPathComponent("Other.mkv"),
                            lastPlayedAt: now.addingTimeInterval(-1), position: 0, duration: 100,
                            thumbnailCacheName: "other"),
    ]
    precondition(ShowFolder.isVolumeRootPath("/Volumes/and"))
    precondition(ShowFolder.make(from: shareRootItems).isEmpty)

    let defaults = UserDefaults(suiteName: "ShowFolderSmoke-\(UUID().uuidString)")!
    let cachedPaths = Set([shows[0].folderURL.standardizedFileURL.path])
    ShowFolderSnapshotStore.save(cachedPaths, defaults: defaults)
    precondition(ShowFolderSnapshotStore.load(defaults: defaults) == cachedPaths)
    print("PASS: only episode-pattern folders become shows; cards use the correct hierarchy and resume progress.")
  }
}
