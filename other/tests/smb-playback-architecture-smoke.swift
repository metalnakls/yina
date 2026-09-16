// xcrun swiftc -parse-as-library other/tests/smb-playback-architecture-smoke.swift -o /tmp/iina-smb-playback-architecture-smoke
// /tmp/iina-smb-playback-architecture-smoke
import Foundation

@main struct SMBPlaybackArchitectureSmoke {
  static func main() throws {
    let playerCore = try String(contentsOfFile: "iina/PlayerCore.swift", encoding: .utf8)

    precondition(!playerCore.contains("com.apple.lastuseddate#PS"),
                 "Playback start must not synchronously write Finder metadata to SMB files")
    precondition(!playerCore.contains("setxattr(fileSystemPath"),
                 "Playback start must not block mpv behind a filesystem metadata write")
    print("PASS: playback start does not synchronously write filesystem metadata.")
  }
}
