import Cocoa
@main struct PlaylistNameSmoke {
  static func main() {
    let item = MPVPlaylistItem(filename: "/Volumes/Shows/S03E03 — Walk with Me.mkv", isCurrent: false, isPlaying: false, title: nil)
    let original = item.filenameForDisplay
    item.title = "The Walking Dead [Season 3] (2012) - Release for HDCLUB"
    item.isCurrent = true
    item.isPlaying = true
    precondition(item.filenameForDisplay == original)
    item.isCurrent = false
    item.isPlaying = false
    precondition(item.filenameForDisplay == original)
    let stream = MPVPlaylistItem(filename: "https://example.com/video", isCurrent: false, isPlaying: false, title: "Stream title")
    precondition(stream.filenameForDisplay == "Stream title")
    stream.title = nil
    precondition(stream.filenameForDisplay == stream.filename)
    print("PASS: local episode names remain stable before, during and after playback; stream titles retained")
  }
}
