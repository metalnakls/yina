#!/usr/bin/env python3
"""Exercise the production resume logger without launching YINA or opening media."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "yina/PlayerCore.swift").read_text()
start = source.index("  private static let resumeTimingLog")
end = source.index("  /// Resume playback.", start)
helper = source[start:end].replace("private func measureResumeStage", "func measureResumeStage")
program = "import Foundation\nimport os.log\nfinal class LoggingSmoke {\n" + helper + "}\n" + '''
let logger = LoggingSmoke()
for _ in 0..<1000 {
  var calls = 0
  let result = logger.measureResumeStage("playButton") { calls += 1; return 42 }
  precondition(result == 42 && calls == 1)
  logger.measureResumeStage("pauseChanged.syncUITime") {}
}
print("PASS: production resume logger survived 2000 calls and preserved operation results")
'''
with tempfile.TemporaryDirectory(prefix="yina-resume-logging-") as folder:
    folder = Path(folder)
    swift = folder / "main.swift"
    binary = folder / "smoke"
    swift.write_text(program)
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(folder / "modules"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
