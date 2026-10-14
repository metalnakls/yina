"""Exercise the production fileLoaded APAC decision with isolated track fixtures."""
from pathlib import Path
import subprocess, tempfile
source = Path('yina/PlayerCore.swift').read_text()
start = source.index('    // Ported from IINA #6472')
end = source.index('    if info.aid == 0 {', start)
block = source[start:end]
fixture = '''
import Foundation
struct Track: CustomStringConvertible {
  let codec: String?
  var description: String { codec ?? "unknown" }
}
final class Info { var aid: Int?; var audioTracks: [Track] = [] }
final class Player {
  enum Kind { case audio }
  enum Level { case warning }
  let info = Info()
  var selected: [Int] = []
  func log(_ message: String, level: Level) {}
  func setTrack(_ id: Int, forType: Kind) { selected.append(id) }
  func applyFallback() {
''' + block + '''
  }
}
func check(_ aid: Int?, _ codecs: [String?], _ expected: [Int]) {
  let player = Player()
  player.info.aid = aid
  player.info.audioTracks = codecs.map { Track(codec: $0) }
  player.applyFallback()
  precondition(player.selected == expected)
}
check(0, ["apple_apac", "aac"], [2])
check(1, ["apple_apac", "aac"], [])
check(2, ["apple_apac", "aac"], [])
check(nil, ["apple_apac", "aac"], [])
check(0, ["aac", "apple_apac"], [])
check(0, ["apple_apac"], [])
check(0, [], [])
check(0, [nil, "aac"], [])
print("PASS: APAC fallback, selected/unknown audio, non-APAC first track, missing alternate and empty tracks")
'''
with tempfile.TemporaryDirectory(prefix='yina-apac-') as directory:
    path = Path(directory)
    (path/'test.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(path/'modules'),str(path/'test.swift'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
