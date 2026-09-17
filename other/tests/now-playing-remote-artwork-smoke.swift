// xcrun swiftc -parse-as-library other/tests/now-playing-remote-artwork-smoke.swift -o /tmp/iina-now-playing-remote-artwork-smoke
// /tmp/iina-now-playing-remote-artwork-smoke
import Foundation

@main struct NowPlayingRemoteArtworkSmoke {
  static func main() throws {
    let source = try String(contentsOfFile: "iina/NowPlayingInfoManager.swift", encoding: .utf8)

    precondition(source.contains("url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal"),
                 "Now Playing artwork must identify mounted remote volumes")
    precondition(source.contains("guard !isMountedRemoteFile else"),
                 "Quick Look artwork must be skipped for mounted remote files")

    let remoteGuard = source.range(of: "guard !isMountedRemoteFile else")!.lowerBound
    let quickLookRequest = source.range(of: "generateQLThumbnail(player, url, ticket)")!.lowerBound
    precondition(remoteGuard < quickLookRequest,
                 "the mounted-volume guard must run before Quick Look starts a second decoder")
    precondition(source[remoteGuard..<quickLookRequest].contains("useOSCThumbnail(player, url)"),
                 "remote files should retain cached OSC artwork without invoking Quick Look")

    print("PASS: mounted remote playback bypasses Quick Look artwork decoding.")
  }
}
