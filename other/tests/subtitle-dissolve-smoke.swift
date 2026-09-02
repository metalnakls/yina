// Standalone smoke test; compiles the production animation against an in-memory mpv stub.
// Run from the repository root:
// xcrun swiftc iina/SubtitleDissolve.swift other/tests/subtitle-dissolve-smoke.swift -o /tmp/iina-subfade-smoke
// /tmp/iina-subfade-smoke
import Cocoa

enum Preference {
  enum Key { case subDissolveAppearDuration, subDissolveDisappearDuration, subDissolveBlurRadius,
                  subDissolveEasing, subDissolveOvershoot }
  static var values: [Key: Float] = [.subDissolveAppearDuration: 0.12, .subDissolveDisappearDuration: 0.16,
                                     .subDissolveBlurRadius: 4, .subDissolveEasing: 3, .subDissolveOvershoot: 0]
  static func float(for key: Key) -> Float { values[key]! }
  static func integer(for key: Key) -> Int { Int(values[key]!) }
}

enum Logger { enum Level { case verbose } }
enum MPVOption {
  enum Subtitles {
    static let subBlur = "sub-blur", subColor = "sub-color", subOutlineColor = "sub-outline-color"
    static let subBackColor = "sub-back-color", subVisibility = "sub-visibility"
  }
}
final class MPVController {
  var visible = true
  var blur = 0.42
  var colors = ["sub-color": "1/0.9/0.8/0.9", "sub-outline-color": "0/0/0/0.8", "sub-back-color": "0/0/0/0"]
  var writes = 0
  func getFlag(_ name: String) -> Bool { visible }
  func getDouble(_ name: String) -> Double { blur }
  func getString(_ name: String) -> String? { colors[name] }
  func setFlag(_ name: String, _ flag: Bool, level: Logger.Level) { visible = flag; writes += 1 }
  func setDouble(_ name: String, _ value: Double, level: Logger.Level) { blur = value; writes += 1 }
  func setString(_ name: String, _ value: String, level: Logger.Level) { colors[name] = value; writes += 1 }
}
extension NSColor {
  convenience init?(mpvColorString: String) {
    let parts = mpvColorString.split(separator: "/").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    self.init(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
  }
  var mpvColorString: String {
    let rgb = usingColorSpace(.sRGB)!
    return "\(rgb.redComponent)/\(rgb.greenComponent)/\(rgb.blueComponent)/\(rgb.alphaComponent)"
  }
}
@main struct Smoke {
  static func run(_ seconds: Double) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
  }
  static func main() {
    let mpv = MPVController()
    let original = mpv.colors
    let dissolve = SubtitleDissolve(mpv: mpv)
    precondition(dissolve.animate(to: false))
    precondition(mpv.visible)
    run(0.06)
    precondition(mpv.blur > 0.42 && mpv.visible)
    let intermediateBlur = mpv.blur
    precondition(dissolve.animate(to: true))
    precondition(abs(mpv.blur - intermediateBlur) < 0.8)
    run(0.2)
    precondition(mpv.visible && mpv.blur == 0.42 && mpv.colors == original)
    precondition(dissolve.targetVisibility == nil)
    dissolve.animate(to: false)
    run(0.22)
    precondition(!mpv.visible && mpv.blur == 0.42 && mpv.colors == original)
    dissolve.animate(to: true)
    precondition(mpv.visible && mpv.blur == 4.42)
    precondition(NSColor(mpvColorString: mpv.colors["sub-color"]!)!.alphaComponent == 0)
    run(0.18)
    precondition(mpv.visible && mpv.blur == 0.42 && mpv.colors == original)
    dissolve.animate(to: false)
    dissolve.finish()
    precondition(!mpv.visible && mpv.blur == 0.42 && mpv.colors == original)
    let writes = mpv.writes
    run(0.2)
    precondition(mpv.writes == writes)
    dissolve.animate(to: true)
    dissolve.abandon()
    let abandonedWrites = mpv.writes
    run(0.2)
    precondition(mpv.writes == abandonedWrites)
    // Restart with an independent core; abandon intentionally does not restore a shut-down core.
    let customMPV = MPVController()
    customMPV.visible = false
    let custom = SubtitleDissolve(mpv: customMPV)
    Preference.values[.subDissolveAppearDuration] = 1.2
    Preference.values[.subDissolveOvershoot] = 0.05
    precondition(custom.animate(to: true))
    run(0.5)
    precondition(custom.targetVisibility == true)
    run(0.36)
    precondition(customMPV.blur < 0.42, "Appearance must sharpen past the saved baseline")
    run(0.45)
    precondition(custom.targetVisibility == nil && customMPV.blur == 0.42)
    Preference.values[.subDissolveDisappearDuration] = 0
    custom.animate(to: false)
    precondition(!customMPV.visible && custom.targetVisibility == nil && customMPV.blur == 0.42)
    for curve in DissolveEasing.allCases {
      for amount in [0.0, 0.05, 1.0] {
        precondition(curve.value(at: 0, overshoot: amount) == 0)
        precondition(curve.value(at: 1, overshoot: amount) == 1)
        if amount > 0 { precondition(abs(curve.value(at: 0.72, overshoot: amount) - (1 + amount)) < 0.00001) }
      }
    }
    print("PASS: custom 1200ms duration, overshoot below baseline, curve endpoints, zero duration, reversal, exact restoration, cancellation.")
  }
}
