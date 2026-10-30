#!/usr/bin/env python3
"""Exercise the production PiP initializer and host layout against system PIP."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
header = (repo / "yina/yina-Bridging-Header.h").read_text()
start = header.index("NS_ASSUME_NONNULL_BEGIN", header.index("#pragma mark - PIP.framework"))
end = header.index("NS_ASSUME_NONNULL_END", start) + len("NS_ASSUME_NONNULL_END")
source = (repo / "yina/VideoPIPViewController.swift").read_text()
source = source[:source.index("\nenum PiPSubtitleGeometry {")]

with tempfile.TemporaryDirectory(prefix="yina-pip-layout-") as directory:
    directory = pathlib.Path(directory)
    bridge = directory / "PIP.h"
    bridge.write_text("#import <Cocoa/Cocoa.h>\n" + header[start:end])
    production = directory / "VideoPIPViewController.swift"
    production.write_text(source)
    binary = directory / "pip-layout"
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(directory / "modules"),
                    "-import-objc-header", str(bridge), "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "PIP", str(production),
                    str(repo / "other/tests/pip-layout-smoke.swift"), "-o", str(binary)],
                   check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
