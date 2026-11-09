// Compile with the libmpv client header, libmpv, and yina/MPVOptionDefaults.swift.
import Foundation
enum MPVProperty {
 static let mpvVersion = "mpv-version"
 static let libassVersion = "libass-version"
}
enum MPVOption { enum ProgramBehavior {
 static let loadAutoProfiles = "load-auto-profiles"
 static let loadCommands = "load-commands"
 static let loadConsole = "load-console"
 static let loadContextMenu = "load-context-menu"
 static let loadPositioning = "load-positioning"
 static let loadScripts = "load-scripts"
 static let loadSelect = "load-select"
 static let loadStatsOverlay = "load-stats-overlay"
}}
enum Logger {
 enum Level { case debug, error }
 enum Sub {}
 static func makeSubsystem(_ name: String) -> String { name }
 static func log(_ message: () -> String, level: Level, subsystem: String) {}
}

@main struct Test {
 static func main() {
  let defaults = MPVOptionDefaults.shared
  let start = Date()
  for _ in 0..<100 { _ = defaults.getString("audio-device"); _ = defaults.getFlag("pause"); _ = defaults.getDouble("volume") }
  precondition(Date().timeIntervalSince(start) < 0.5, "Defaults blocked the calling thread")
  var versions: (String?, String?)?
  var result: String?
  var completed = false
  var backgroundCompleted = false
  var missingCompleted = false
  defaults.getVersions { mpv, ass in versions = (mpv, ass) }
  defaults.getDefaultString("audio-device") { value in
    precondition(Thread.isMainThread)
    result = value
    completed = true
  }
  defaults.getDefaultString("yina-nonexistent-option-for-test") { value in
    precondition(value == nil, "Missing option must not return a fake default")
    missingCompleted = true
  }
  DispatchQueue.global(qos: .userInitiated).async {
    defaults.getDefaultString("audio-device") { value in
      precondition(Thread.isMainThread && value != nil)
      backgroundCompleted = true
    }
  }
  let deadline = Date().addingTimeInterval(20)
  while (!completed || !backgroundCompleted || !missingCompleted || versions == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
  precondition(completed && backgroundCompleted && missingCompleted && versions != nil, "Timed out")
  precondition(versions!.0?.contains("mpv") == true && versions!.1 != nil, "Real versions missing")
  precondition(result != nil && defaults.getString("audio-device") == result, "Real default missing from cache")
  precondition(defaults.getFlag("pause") == false, "Flag default not read correctly")
  precondition(defaults.getDouble("volume") != nil, "Double default missing")
  print("PASS: real mpv defaults and versions; main thread remained responsive")
 }
}
