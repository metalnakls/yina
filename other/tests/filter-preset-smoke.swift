// xcrun swiftc iina/MPVFilter.swift iina/FilterPresets.swift other/tests/filter-preset-smoke.swift -o /tmp/iina-filter-preset-smoke
// /tmp/iina-filter-preset-smoke
import Foundation

enum Logger {
  enum Level { case warning }
  static func log(_ message: String, level: Level) {}
}

extension Collection {
  subscript(at index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

extension String {
  var mpvFixedLengthQuoted: String { "%\(self.utf8.count)%\(self)" }
}

@main struct FilterPresetSmoke {
  static func main() {
    guard let preset = FilterPreset.afPresets.first(where: { $0.name == "custom_mpv" }) else {
      preconditionFailure("Custom mpv filter preset is missing")
    }

    let invalid = FilterPresetInstance(from: preset)
    invalid.params["name"] = FilterParameterValue(string: "@missing-colon")
    invalid.params["string"] = FilterParameterValue(string: "value")
    precondition(preset.transformer(invalid) == nil)

    let valid = FilterPresetInstance(from: preset)
    valid.params["name"] = FilterParameterValue(string: "@label:volume")
    valid.params["string"] = FilterParameterValue(string: "2")
    precondition(preset.transformer(valid)?.stringFormat == "@label:volume=2")

    print("PASS: custom mpv filter presets reject malformed labels without crashing.")
  }
}
