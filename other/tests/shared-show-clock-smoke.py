#!/usr/bin/env python3
"""Compile and exercise the pure Watch Together host-clock estimator."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-clock-") as directory:
    binary = Path(directory) / "clock-smoke"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-cache-path", str(Path(directory) / "module-cache"),
        str(repo / "yina/SharedShowClock.swift"),
        str(repo / "other/tests/shared-show-clock-smoke.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
