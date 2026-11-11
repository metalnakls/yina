#!/usr/bin/env python3
"""Exercise Watch Together barriers against a deterministic playback engine."""
from pathlib import Path
import shutil
import subprocess
import tempfile


repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-sync-invariants-") as directory:
    root = Path(directory)
    (root / "A.mkv").write_bytes(b"fixture")
    sources = []
    for name in ("SharedShowSession.swift", "SharedShowLAN.swift", "SharedShowClock.swift", "SharedShowStore.swift",
                 "ShowEpisodeIndexReader.swift", "PlayerState.swift", "SharedShowDownloadRequest.swift"):
        copy = root / name
        shutil.copyfile(repo / "yina" / name, copy)
        sources.append(copy)
    binary = root / "sync-invariants"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos27.0",
                    "-module-cache-path", str(root / "modules"),
                    *map(str, [*sources, repo / "other/tests/shared-show-sync-invariants-smoke.swift"]),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(root)], check=True)
