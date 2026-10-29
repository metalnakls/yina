#!/usr/bin/env python3
"""Exercise the production PiP entry plan without launching the installed app."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/MainWindowController.swift").read_text()
start = source.index("struct PiPEntryPlan {")
end = source.index("\nclass MainWindowController:", start)
with tempfile.TemporaryDirectory(prefix="yina-pip-transition-") as directory:
    directory = pathlib.Path(directory)
    production = directory / "transition.swift"
    production.write_text("enum Preference { enum WindowBehaviorWhenPip { case doNothing, hide, minimize } }\n" +
                          source[start:end])
    binary = directory / "transition"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(directory / "modules"),
                    str(production), str(repo / "other/tests/pip-transition-smoke.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
