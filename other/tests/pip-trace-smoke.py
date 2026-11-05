#!/usr/bin/env python3
"""Exercise the actual automatic PiP trace and its asynchronous file writer."""
import pathlib
import subprocess
import tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-pip-trace-") as directory:
    root = pathlib.Path(directory)
    binary = root / "probe"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", "/private/tmp/yina-event-module-cache",
                    str(repo / "yina/PiPTransitionTrace.swift"),
                    str(repo / "other/tests/pip-trace-smoke.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(root / "traces")], check=True, timeout=15)
