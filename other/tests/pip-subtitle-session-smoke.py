#!/usr/bin/env python3
"""Compile the production PiP suppression reconciler against a controlled mpv reply stub."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/MainWindowController.swift").read_text()
start = source.index("  private func reconcilePiPSubtitlePresentation() {")
end = source.index("\n  func enterPIP() {", start)
with tempfile.TemporaryDirectory(prefix="yina-pip-session-") as directory:
    directory = pathlib.Path(directory)
    production = directory / "session.swift"
    production.write_text((repo / "other/tests/pip-subtitle-session-stubs.swift").read_text()
                          .replace("// PRODUCTION_RECONCILER", source[start:end]))
    binary = directory / "session"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(directory / "modules"),
                    str(production), str(repo / "other/tests/pip-subtitle-session-smoke.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
