#!/usr/bin/env python3
"""Exercise the production Finder callback with recording playback/UI boundaries.

Run from the repository root: python3 other/tests/finder-open-smoke.py
"""
import pathlib
import subprocess
import tempfile

source = pathlib.Path("yina/AppDelegate.swift").read_text()
start = source.index("  func application(_ sender: NSApplication, openFiles filenames: [String]) {")
end = source.index("\n  /// Method to opt-in to secure restorable state.", start)
callback = source[start:end]

harness = r'''
import Cocoa

final class RecordingApplication: NSApplication {
  var replies: [NSApplication.DelegateReply] = []
  override func reply(toOpenOrPrint reply: NSApplication.DelegateReply) {
    replies.append(reply)
  }
}

enum PlayerCore {
  static var batches: [[URL]] = []
  static var result: Int? = 1
  static func openURLs(_ urls: [URL]) -> Int? {
    batches.append(urls)
    return result
  }
}
final class SettingsWindow {
  static let `default` = SettingsWindow()
  var packages: [URL] = []
  func installPlugin(localPackageURL: URL) { packages.append(localPackageURL) }
}
enum Utility {
  static var alerts: [String] = []
  static func showAlert(_ key: String) { alerts.append(key) }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  var openFileCalled = false
  var isReady = false
  var shouldIgnoreOpenFile = false
  var readyCount = 0
  func getReady() { readyCount += 1; isReady = true }
''' + callback + r'''
}

let app = RecordingApplication.shared as! RecordingApplication
app.setActivationPolicy(.prohibited)
let delegate = AppDelegate()
app.delegate = delegate
let files = ["/tmp/first clip.mp4", "/tmp/second clip.mkv"]

// Calls must route synchronously: no run-loop turn or debounce timer is needed.
delegate.application(app, openFiles: files)
precondition(PlayerCore.batches == [files.map { URL(fileURLWithPath: $0) }])
precondition(delegate.openFileCalled && delegate.readyCount == 1)
precondition(app.replies == [.success])
delegate.application(app, openFiles: [files[0]])
precondition(PlayerCore.batches.count == 2 && PlayerCore.batches[1].count == 1)
precondition(delegate.readyCount == 1)

// CLI suppression consumes exactly one request, without retaining stale filenames.
delegate.shouldIgnoreOpenFile = true
delegate.application(app, openFiles: files)
precondition(!delegate.shouldIgnoreOpenFile && PlayerCore.batches.count == 2)
delegate.application(app, openFiles: [files[1]])
precondition(PlayerCore.batches.last == [URL(fileURLWithPath: files[1])])

let beforePlugin = PlayerCore.batches.count
delegate.application(app, openFiles: ["/tmp/example.iinaplgz"])
precondition(SettingsWindow.default.packages.count == 1)
precondition(PlayerCore.batches.count == beforePlugin && app.replies.last == .success)

PlayerCore.result = 0
delegate.application(app, openFiles: ["/tmp/unsupported.exe"])
precondition(app.replies.last == .failure && Utility.alerts == ["nothing_to_open"])
PlayerCore.result = nil // Blu-ray/playlist requests are handled without a count.
delegate.application(app, openFiles: ["/tmp/playlist.m3u"])
precondition(app.replies.last == .success)
delegate.application(app, openFiles: [])
precondition(app.replies.count == 8 && app.replies.last == .success)
print("PASS: immediate single/batch routing, CLI suppression, plugin routing and AppKit replies")
'''

with tempfile.TemporaryDirectory(prefix="yina-finder-open-") as temp:
    swift = pathlib.Path(temp) / "main.swift"
    binary = pathlib.Path(temp) / "finder-open-smoke"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(pathlib.Path(temp) / "ModuleCache"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
