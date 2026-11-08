#!/usr/bin/env python3
"""Execute production timer lifecycle methods with counted UI/cache consumers."""
import pathlib
import subprocess
import tempfile
repo = pathlib.Path(__file__).resolve().parents[2]

def method(source, name):
    start = source.rfind('\n', 0, source.index('func ' + name)) + 1
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

extensions = (repo / 'yina/Extensions.swift').read_text()
start = extensions.index('extension Timer {')
end = extensions.index('\nextension NSEvent', start)
base = r'''
import Cocoa
struct Logger {
  enum Level { case verbose }
  static func isEmitting(_ level: Level) -> Bool { false }
  static func log(_ text: String, level: Level, subsystem: String) {}
}
enum State { case playing, paused, stopped; var active: Bool { self != .stopped } }
struct Info { var state = State.playing; var isRemotePlayback = true; var isNetworkResource = false }
struct Window { var shown = false; func isUITimerNeeded() -> Bool { shown } }
struct DurationDisplayTextField { static var precision = 0 }
struct AppData { static let syncTimeInterval = 0.1; static let syncTimePreciseInterval = 0.04 }
class Probe: NSObject {
  var info = Info(); var mainWindow = Window(); var isInMiniPlayer = false
  var syncUITimer: Timer?; var networkBufferTimer: Timer?
  let subsystem = "test"
  var ui = 0; var cache = 0; var lastCache = 0.0
  func updateNetworkStreamCacheState() {
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastCache >= 0.5 { cache += 1; lastCache = now }
  }
  @objc func syncUITime() {
    ui += 1
    if BASELINE && info.isRemotePlayback { updateNetworkStreamCacheState() }
  }
'''
main = r'''
}
func run(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
for precision in [0, 2] {
  DurationDisplayTextField.precision = precision
  let p = Probe()
  p.refreshSyncUITimer()
  let initialUI = p.ui
  run(1.22)
  let hiddenUI = p.ui - initialUI
  print("COMPARISON precision=\(precision) hidden UI ticks=\(hiddenUI) cache checks=\(p.cache)")
  if !BASELINE { precondition(hiddenUI == 0 && p.cache >= 2 && p.cache <= 3) }
  p.mainWindow.shown = true
  p.refreshSyncUITimer()
  let shownUI = p.ui
  run(0.25)
  precondition(p.ui > shownUI)
  p.mainWindow.shown = false
  p.refreshSyncUITimer()
  p.info.state = .paused
  p.refreshSyncUITimer()
  let pausedUI = p.ui; let pausedCache = p.cache
  run(0.55)
  precondition(p.ui == pausedUI && p.cache == pausedCache)
  p.info.state = .playing
  p.refreshSyncUITimer()
  run(0.55)
  precondition(p.cache > pausedCache)
  p.info.isRemotePlayback = false
  p.refreshSyncUITimer()
  let localCache = p.cache
  run(0.55)
  precondition(p.cache == localCache)
  p.info.state = .stopped
  p.refreshSyncUITimer()
  precondition(p.syncUITimer?.isValid != true && p.networkBufferTimer?.isValid != true)
}
print("PASS: hidden/visible, precision, pause/resume, local playback and shutdown timer lifecycle")
'''
with tempfile.TemporaryDirectory(prefix='yina-remote-timer-') as directory:
    root = pathlib.Path(directory)
    for baseline in [True, False]:
        source = subprocess.check_output(['git', 'show', '55673db4:yina/PlayerCore.swift'], cwd=repo, text=True) if baseline else (repo / 'yina/PlayerCore.swift').read_text()
        code = base + method(source, 'refreshSyncUITimer')
        if not baseline:
            code += '\n' + method(source, 'refreshNetworkBufferTimer')
        code += main + extensions[start:end]
        code = code.replace('BASELINE', 'true' if baseline else 'false')
        swift = root / 'main.swift'; swift.write_text(code)
        binary = root / 'probe'
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', '/private/tmp/yina-event-module-cache', str(swift), '-o', str(binary)], check=True)
        print('BEFORE' if baseline else 'AFTER', flush=True)
        subprocess.run([str(binary)], check=True, timeout=15)
