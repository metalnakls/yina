#!/usr/bin/env python3
"""Exercise PlayerCore's production fullscreen sync against short-file startup."""
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
source = (ROOT / "yina/PlayerCore.swift").read_text()


def extract_method(name: str) -> str:
    start = source.index(f"func {name}(")
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"Unclosed production method: {name}")


fullscreen_changed = extract_method("fullscreenChanged")
check_unsynced = extract_method("checkUnsyncedWindowOptions")
apply_fullscreen_on_open = extract_method("applyFullScreenWhenOpenPreference")

assert "keepCurrentFileWindowed = isManuallyOpenedShortFile" in source
assert "duration < Self.shortFileLoopThreshold" in source
notify_video_size = source[source.index("func notifyWindowVideoSizeChanged()"):]
assert "applyFullScreenWhenOpenPreference()" in notify_video_size

swift = r'''
import Foundation

enum MPVOption {
  enum Window {
    static let fullscreen = "fullscreen"
    static let ontop = "ontop"
  }
}

enum Preference {
  enum Key { case fullScreenWhenOpen }
  static var fullScreenWhenOpen = false
  static func bool(for key: Key) -> Bool { fullScreenWhenOpen }
}

struct PlaybackState { var active = true }
final class PlaybackInfo { var state = PlaybackState() }

final class StubMPV {
  private(set) var flags = [String: Bool]()
  func getFlag(_ name: String) -> Bool { flags[name, default: false] }
  func setFlag(_ name: String, _ value: Bool) { flags[name] = value }
}

final class StubWindow {
  enum FullScreenState {
    case windowed
    case fullscreen
    case animating(toFullscreen: Bool)

    var isFullscreen: Bool {
      switch self {
      case .fullscreen: true
      case .animating(let toFullscreen): toFullscreen
      case .windowed: false
      }
    }
  }

  var loaded = true
  var fsState = FullScreenState.windowed
  var isFullscreen: Bool {
    get { fsState.isFullscreen }
    set { fsState = newValue ? .fullscreen : .windowed }
  }
  var isOntop = false
  var toggleCount = 0

  func toggleWindowFullScreen() {
    toggleCount += 1
    switch fsState {
    case .windowed: fsState = .animating(toFullscreen: true)
    case .fullscreen: fsState = .animating(toFullscreen: false)
    case .animating: break
    }
  }
  func finishFullscreenTransition() {
    switch fsState {
    case .animating(let toFullscreen): fsState = toFullscreen ? .fullscreen : .windowed
    case .windowed, .fullscreen: break
    }
  }
  func setWindowFloatingOnTop(_ value: Bool, updateOnTopStatus: Bool) {
    isOntop = value
  }
}

final class PlayerCoreHarness {
  let mainWindow = StubWindow()
  let info = PlaybackInfo()
  let mpv = StubMPV()
  var keepCurrentFileWindowed = true
  var isInMiniPlayer = false

  __FULLSCREEN_CHANGED__

  __CHECK_UNSYNCED__

  __APPLY_FULLSCREEN_ON_OPEN__
}

let player = PlayerCoreHarness()
player.checkUnsyncedWindowOptions()
precondition(!player.mainWindow.isFullscreen, "Short file must remain windowed at load")
precondition(!player.mpv.getFlag(MPVOption.Window.fullscreen), "Startup fullscreen must be cleared")
Preference.fullScreenWhenOpen = true
player.applyFullScreenWhenOpenPreference()
precondition(!player.mainWindow.isFullscreen, "Short-file policy must suppress fullScreenWhenOpen")
precondition(!player.keepCurrentFileWindowed, "Startup window policy must be consumed after load")

// Manual enter and exit transitions update mpv to the native animation target; PlayerCore must not reverse them.
player.mainWindow.toggleWindowFullScreen()
player.mpv.setFlag(MPVOption.Window.fullscreen, true)
player.fullscreenChanged()
precondition(player.mainWindow.toggleCount == 1, "Manual fullscreen entry must not be reversed")
if case .animating(toFullscreen: true) = player.mainWindow.fsState {} else {
  preconditionFailure("Manual fullscreen entry target must remain active")
}
player.mainWindow.finishFullscreenTransition()
player.mainWindow.toggleWindowFullScreen()
player.mpv.setFlag(MPVOption.Window.fullscreen, false)
player.fullscreenChanged()
precondition(player.mainWindow.toggleCount == 2, "Manual fullscreen exit must not be reversed")
if case .animating(toFullscreen: false) = player.mainWindow.fsState {} else {
  preconditionFailure("Manual fullscreen exit target must remain windowed")
}
player.mainWindow.finishFullscreenTransition()
precondition(!player.mainWindow.isFullscreen, "Manual fullscreen exit must finish windowed")

// A short file opened while the native window is fullscreen must exit and clear mpv's flag.
let alreadyFullscreen = PlayerCoreHarness()
alreadyFullscreen.mainWindow.fsState = .fullscreen
alreadyFullscreen.mpv.setFlag(MPVOption.Window.fullscreen, true)
alreadyFullscreen.checkUnsyncedWindowOptions()
precondition(!alreadyFullscreen.mpv.getFlag(MPVOption.Window.fullscreen), "Startup must clear mpv fullscreen")
if case .animating(toFullscreen: false) = alreadyFullscreen.mainWindow.fsState {} else {
  preconditionFailure("Startup must request exit from native fullscreen")
}
alreadyFullscreen.mainWindow.finishFullscreenTransition()
precondition(!alreadyFullscreen.mainWindow.isFullscreen, "Short-file startup must finish windowed")

// Longer files retain the existing automatic-fullscreen preference.
let longerFile = PlayerCoreHarness()
longerFile.keepCurrentFileWindowed = false
longerFile.applyFullScreenWhenOpenPreference()
if case .animating(toFullscreen: true) = longerFile.mainWindow.fsState {} else {
  preconditionFailure("Non-short files must retain fullScreenWhenOpen")
}

// Ignore synchronization callbacks before the player window loads or while playback is idle.
let unloaded = PlayerCoreHarness()
unloaded.mainWindow.loaded = false
unloaded.mpv.setFlag(MPVOption.Window.fullscreen, true)
unloaded.fullscreenChanged()
precondition(unloaded.mainWindow.toggleCount == 0, "Unloaded fullscreen sync must be ignored")
let idle = PlayerCoreHarness()
idle.info.state.active = false
idle.mpv.setFlag(MPVOption.Window.fullscreen, true)
idle.fullscreenChanged()
precondition(idle.mainWindow.toggleCount == 0, "Idle fullscreen sync must be ignored")
print("PASS: manually opened short files start windowed and respect later manual fullscreen")
'''.replace("__FULLSCREEN_CHANGED__", fullscreen_changed).replace("__CHECK_UNSYNCED__", check_unsynced).replace(
    "__APPLY_FULLSCREEN_ON_OPEN__", apply_fullscreen_on_open
)

with tempfile.TemporaryDirectory(prefix="yina-short-file-fullscreen-") as directory:
    source_path = pathlib.Path(directory) / "main.swift"
    binary_path = pathlib.Path(directory) / "probe"
    source_path.write_text(swift)
    subprocess.run([
        "xcrun", "swiftc", "-module-cache-path", "/private/tmp/yina-fullscreen-module-cache",
        str(source_path), "-o", str(binary_path)
    ], check=True)
    subprocess.run([str(binary_path)], check=True)
