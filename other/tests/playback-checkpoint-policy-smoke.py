#!/usr/bin/env python3
"""Exercise checkpoint timing and production submission guards without media."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/PlayerCore.swift").read_text()
helper = source[source.index("struct PlaybackPositionCheckpoint {"):source.index("\nclass PlayerCore:")]
def method(signature):
    start = source.index("  " + signature)
    return source[start:source.index("\n  }", start) + len("\n  }")]
fixture = (repo / "other/tests/playback-crash-recovery-smoke.swift").read_text().split("@main struct CrashRecoverySmoke")[0]
fixture = fixture.replace("// CHECKPOINT_HELPER", helper)
fixture = fixture.replace("// CHECKPOINT_PROPERTY", "var playbackCheckpoint = PlaybackPositionCheckpoint()")
fixture = fixture.replace("// PRODUCTION_METHODS", "\n".join(method(name) for name in
    ["func updateObservedPlayback(", "func checkpointPlaybackPosition(", "func clearCompletedPlaybackCheckpoint("]))
fixture = fixture.replace("final class Engine { let asyncClient = MPVAsyncClient() }", """
final class FakeClient {
  var commands: [[String]] = []
  var completions: [(Int32) -> Void] = []
  func command(_ arguments: [String], completion: @escaping (Int32) -> Void = { _ in }) {
    commands.append(arguments)
    completions.append(completion)
  }
}
final class Engine { let asyncClient = FakeClient() }
""")
with tempfile.TemporaryDirectory(prefix="yina-checkpoint-policy-") as directory:
    root = pathlib.Path(directory)
    swift = root / "fixture.swift"
    swift.write_text(fixture)
    binary = root / "policy"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", "/private/tmp/yina-event-module-cache",
                    str(repo / "yina/PlayerState.swift"), str(swift),
                    str(repo / "other/tests/playback-checkpoint-policy-smoke.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=5)
