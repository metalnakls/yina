#!/usr/bin/env python3
"""Run production HDR classification and option policy without launching yina."""
import pathlib
import subprocess
import tempfile

source = pathlib.Path("yina/VideoView.swift").read_text()
start = source.index("  private func isHDRVideo() -> Bool {")
end = source.index("\n  func requestEdrMode()", start)
classification = source[start:end].replace("private func", "func", 1)
start = source.index("  private func setToneMappingForHDR(passthrough: Bool) {")
end = source.index("\n  /// Return the output peak", start)
policy = source[start:end].replace("private func", "func", 1)

harness = r'''
import Foundation

enum Level { case warning, error }
enum MPVProperty {
  static let videoParamsGamma = "gamma", videoParamsPrimaries = "primaries", videoParamsSigPeak = "peak"
}
enum MPVOption {
  enum GPURendererOptions {
    static let inverseToneMapping = "inverse", targetPeak = "peak", toneMapping = "algorithm"
  }
}
enum Preference {
  enum Key { case enableToneMapping, toneMappingAlgorithm }
  enum ToneMappingAlgorithmOption { case auto }
  static func bool(for key: Key) -> Bool { true }
  static func `enum`<T>(for key: Key) -> T { ToneMappingAlgorithmOption.auto as! T }
}
final class MPV {
  var gamma: String?
  var primaries: String?
  var options: [String: String] = [:]
  init(_ gamma: String?, _ primaries: String?) { self.gamma = gamma; self.primaries = primaries }
  func getString(_ name: String) -> String? { name == "gamma" ? gamma : primaries }
  func getDouble(_ name: String) -> Double { 4 }
  func setFlag(_ name: String, _ value: Bool) { options[name] = value ? "yes" : "no" }
  func setString(_ name: String, _ value: String) { options[name] = value }
  func setStringToDefault(_ name: String) { options[name] = "default" }
}
final class Player {
  var mpv: MPV?
  init(_ mpv: MPV) { self.mpv = mpv }
}
final class Probe {
  let player: Player
  init(_ gamma: String?, _ primaries: String?) { player = Player(MPV(gamma, primaries)) }
  func logHDR(_ value: String, level: Level = .warning) { }
  func toneMappingTargetPeak() -> String { "1600" }
''' + classification + policy + r'''
}
for (gamma, primaries) in [("pq", "bt.2020"), ("pq", "bt.709"),
                           ("hlg", "bt.2020"), ("hlg", "unknown")] {
  let probe = Probe(gamma, primaries)
  precondition(probe.isHDRVideo(), "HDR transfer must never enter SDR expansion")
  // Simulate a previous SDR-to-EDR source, then switch to native HDR.
  probe.player.mpv!.options = ["inverse": "yes", "peak": "1600", "algorithm": "reinhard"]
  probe.setToneMappingForHDR(passthrough: true)
  precondition(probe.player.mpv!.options == ["inverse": "no", "peak": "default", "algorithm": "default"])
}
precondition(!Probe("bt.1886", "bt.2020").isHDRVideo())
precondition(!Probe(nil, nil).isHDRVideo())
let fallback = Probe("pq", "bt.2020")
fallback.setToneMappingForHDR(passthrough: false)
precondition(fallback.player.mpv!.options["inverse"] == "no")
precondition(fallback.player.mpv!.options["peak"] == "1600", "HDR-to-SDR mapping must remain available")
print("PASS: HDR classification, SDR-to-HDR transition reset, native passthrough and SDR-display fallback")
'''
with tempfile.TemporaryDirectory(prefix="yina-hdr-policy-") as directory:
    root = pathlib.Path(directory)
    swift = root / "main.swift"
    binary = root / "probe"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(root / "modules"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
