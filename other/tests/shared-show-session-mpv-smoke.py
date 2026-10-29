#!/usr/bin/env python3
"""Drive production Watch Together code with two bundled libmpv cores and generated video."""
from pathlib import Path
import subprocess
import tempfile
import shutil

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-shared-mpv-") as directory:
    root = Path(directory)
    for episode in ("A", "B"):
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                        f"color=black:size=64x36:rate=24:duration=30", "-c:v", "ffv1", "-y",
                        str(root / f"{episode}.mkv")], check=True)
    header = root / "mpv.h"
    header.write_text("#include <mpv/client.h>\n")
    sources = []
    names = ["SharedShowSession.swift", "SharedShowStore.swift",
             "ShowEpisodeIndexReader.swift", "PlayerState.swift"]
    if (repo / "yina/SharedShowDownloadRequest.swift").exists():
        names.append("SharedShowDownloadRequest.swift")
    for name in names:
        copy = root / name
        shutil.copyfile(repo / "yina" / name, copy)
        sources.append(copy)
    binary = root / "session"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos27.0",
                    "-module-cache-path", str(root / "modules"), "-I", str(repo / "deps/include"),
                    "-import-objc-header", str(header),
                    *map(str, [*sources, repo / "other/tests/shared-show-session-mpv-smoke.swift"]),
                    str(repo / "deps/lib/libmpv.2.dylib"), "-Xlinker", "-rpath", "-Xlinker",
                    str(repo / "deps/lib"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(root)], check=True, timeout=90)
