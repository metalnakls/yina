#!/usr/bin/env python3
"""Compile and exercise the PiP subtitle placement used by the AppKit panel."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/VideoPIPViewController.swift").read_text()
start = source.index("enum PiPSubtitleGeometry {")
end = source.index("\n/// Plain-text subtitle surface", start)
with tempfile.TemporaryDirectory(prefix="yina-pip-subtitles-") as directory:
    directory = pathlib.Path(directory)
    production = directory / "geometry.swift"
    production.write_text("import AppKit\n" + source[start:end])
    binary = directory / "geometry"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(directory / "modules"),
                    str(production), str(repo / "other/tests/pip-subtitle-geometry-smoke.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
