"""Compare the production series matcher with the previous full-matrix result."""
from pathlib import Path
import os
import subprocess
import tempfile

source = Path('yina/AutoFileMatcher.swift').read_text()
method = source[source.index('  private func matchVideoAndSubSeries()'):source.index('  private func matchSubs(', source.index('  private func matchVideoAndSubSeries()'))]
fixture = r'''import Foundation
struct FileInfo {}
enum Logger { enum Level { case debug } }
enum ObjcUtils {
  static var calls = 0
  static func levDistance(_ a: String, and b: String) -> UInt {
    calls += 1
    let x = Array(a.utf16), y = Array(b.utf16)
    var row = Array(0...y.count)
    for (i, c) in x.enumerated() {
      var next = [i + 1] + Array(repeating: 0, count: y.count)
      for (j, d) in y.enumerated() {
        next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (c == d ? 0 : 1))
      }
      row = next
    }
    return UInt(row[y.count])
  }
}
final class Matcher {
  var videosGroupedBySeries: [String: [FileInfo]] = [:]
  var subsGroupedBySeries: [String: [FileInfo]] = [:]
  func checkTicket() throws {}
  func log(_ text: @autoclosure () -> String, level: Logger.Level = .debug) {}
  func run() throws -> [String: String] { try matchVideoAndSubSeries() }
'''+method+r'''
}
func previous(_ videos: [String: [FileInfo]], _ subs: [String: [FileInfo]]) -> [String: String] {
  var distances: [String: [String: UInt]] = [:]
  var closest: [String: String] = [:]
  for (sp, _) in subs {
    distances[sp] = [:]
    var minDist = UInt.max, best = ""
    for (vp, vl) in videos where vl.count > 2 {
      let dist = ObjcUtils.levDistance(vp, and: sp)
      distances[sp]![vp] = dist
      if dist < minDist { minDist = dist; best = vp }
    }
    closest[sp] = best
  }
  var matched: [String: String] = [:]
  for (vp, vl) in videos where vl.count > 2 {
    var minDist = UInt.max, best = ""
    for (sp, _) in subs {
      let dist = distances[sp]![vp]!
      if dist < minDist { minDist = dist; best = sp }
    }
    let threshold = UInt(Double(vp.count + best.count) * 0.6)
    if closest[best] == vp && minDist < threshold { matched[vp] = best }
  }
  return matched
}
@main enum Smoke {
  static func main() throws {
    let matcher = Matcher()
    for round in 0..<200 {
      matcher.videosGroupedBySeries = [:]
      matcher.subsGroupedBySeries = [:]
      for index in 0..<15 {
        let prefix = String(repeating: Character(UnicodeScalar(65 + (index + round) % 20)!), count: 1 + (index * 7 + round) % 30)
        matcher.videosGroupedBySeries[prefix] = Array(repeating: FileInfo(), count: index % 5)
      }
      for index in 0..<15 {
        let prefix = String(repeating: Character(UnicodeScalar(65 + (index * 3 + round) % 20)!), count: 1 + (index * 11 + round) % 30)
        matcher.subsGroupedBySeries[prefix] = [FileInfo()]
      }
      let expected = previous(matcher.videosGroupedBySeries, matcher.subsGroupedBySeries)
      let actual = try matcher.run()
      precondition(actual == expected, "series matching changed in round \(round)")
    }
    print("PASS: production series matcher equals full-matrix matching on 200 synthetic folders")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-matcher-test-') as directory:
    path = Path(directory)
    (path/'test.swift').write_text(fixture)
    cache = path/'module-cache'
    cache.mkdir()
    env = {**os.environ, 'CLANG_MODULE_CACHE_PATH': str(cache), 'SWIFT_MODULE_CACHE_PATH': str(cache)}
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(cache), str(path/'test.swift'), '-o', str(path/'test')], check=True, env=env)
    subprocess.run([str(path/'test')], check=True, timeout=30)
