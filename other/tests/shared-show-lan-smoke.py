#!/usr/bin/env python3
"""Compile production LAN transport with minimal session stubs, then use real Bonjour/TCP.

Run in the approved local context with Local Network and WindowServer access.
A restricted sandbox may time out at discovery even though the same binary passes
outside it. No user app, SMB share, or media file is opened by this test.
"""
from pathlib import Path
import subprocess
import shutil
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-shared-lan-") as directory:
    root = Path(directory)
    binary = root / "shared-show-lan-smoke"
    lan_source = root / "SharedShowLAN.swift"
    shutil.copyfile(repo / "yina/SharedShowLAN.swift", lan_source)
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-cache-path", str(root / "modules"),
        str(repo / "other/tests/shared-show-lan-smoke.swift"),
        str(lan_source),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=40)
