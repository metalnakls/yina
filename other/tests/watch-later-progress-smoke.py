#!/usr/bin/env python3
"""Read real watch-later layouts through the production progress reader."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/Utility.swift").read_text()
start = source.index("  static func playbackProgressFromWatchLater(")
method = source[start:source.index("\n  }", start) + len("\n  }")]
with tempfile.TemporaryDirectory(prefix="yina-watch-later-reader-") as directory:
    root = pathlib.Path(directory)
    swift = root / "reader.swift"
    swift.write_text("import Foundation\nstruct VideoTime { let second: Double; init(_ value: Double) { second = value } }\n" +
                     "enum Utility { static var watchLaterURL = URL(fileURLWithPath: CommandLine.arguments[1])\n" + method + "\n}\n")
    binary = root / "reader"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", "/private/tmp/yina-event-module-cache",
                    str(repo / "yina/StreamReader.swift"), str(swift),
                    str(repo / "other/tests/watch-later-progress-smoke.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(root)], check=True)
