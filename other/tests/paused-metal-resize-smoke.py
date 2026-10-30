#!/usr/bin/env python3
"""Resize the production Metal layer with generated media while mpv is paused."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-paused-metal-resize-") as directory:
    root = pathlib.Path(directory)
    fixture = root / "gray.mkv"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=gray:size=320x180:rate=24:duration=2", "-c:v", "ffv1", "-y", str(fixture)],
                   check=True)
    header = root / "mpv.h"
    header.write_text("#include <mpv/client.h>\n#include <mpv/render.h>\n#include <mpv/render_mtl.h>\n")
    binary = root / "resize"
    sources = [repo / "yina" / name for name in
               ["Lock.swift", "Atomic.swift", "ReadWriteLock.swift", "ReadWriteAtomic.swift", "ViewLayer.swift"]]
    subprocess.run(["xcrun", "swiftc", "-D", "IINA_ENABLE_METAL_RENDERER",
                    "-module-cache-path", "/private/tmp/yina-event-module-cache",
                    "-I", str(repo / "deps/include"), "-import-objc-header", str(header),
                    *map(str, sources), str(repo / "other/tests/paused-metal-resize-smoke.swift"),
                    str(repo / "deps/lib/libmpv.2.dylib"), "-Xlinker", "-rpath", "-Xlinker",
                    str(repo / "deps/lib"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(fixture)], check=True, timeout=30)
