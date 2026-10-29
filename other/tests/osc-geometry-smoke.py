#!/usr/bin/env python3
"""Compile the production OSC geometry in isolation; no app or personal media."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/OSCFloatingView.swift").read_text()
start = source.index("enum OSCFloatingGeometry {")
end = source.index("\nclass OSCFloatingView:", start)
with tempfile.TemporaryDirectory(prefix="yina-osc-geometry-") as directory:
    directory = pathlib.Path(directory)
    production = directory / "geometry.swift"
    production.write_text("import AppKit\n" + source[start:end])
    main = directory / "main.swift"
    main.write_text((repo / "other/tests/osc-geometry-smoke.swift").read_text())
    binary = directory / "geometry"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(directory / "modules"),
                    str(production), str(main),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
