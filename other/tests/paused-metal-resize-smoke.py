#!/usr/bin/env python3
"""Resize the production Metal layer with generated media while mpv is paused."""
import pathlib
import subprocess
import tempfile
import sys

repo = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-paused-metal-resize-") as directory:
    root = pathlib.Path(directory)
    fixture = root / "gray.mkv"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=gray:size=320x180:rate=24:duration=2", "-c:v", "ffv1", "-y", str(fixture)],
                   check=True)
    header = root / "mpv.h"
    bridge = (repo / "yina/yina-Bridging-Header.h").read_text()
    start = bridge.index("NS_ASSUME_NONNULL_BEGIN", bridge.index("#pragma mark - PIP.framework"))
    end = bridge.index("NS_ASSUME_NONNULL_END", start) + len("NS_ASSUME_NONNULL_END")
    header.write_text("#import <Cocoa/Cocoa.h>\n#include <mpv/client.h>\n#include <mpv/render.h>\n#include <mpv/render_mtl.h>\n" + bridge[start:end])
    binary = root / "resize"
    sources = [repo / "yina" / name for name in
               ["Lock.swift", "Atomic.swift", "ReadWriteLock.swift", "ReadWriteAtomic.swift", "PiPTransitionTrace.swift", "ViewLayer.swift"]]
    baseline = "--baseline" in sys.argv
    if baseline:
        old = root / "ViewLayer.swift"
        old.write_text(subprocess.check_output(["git", "show", "55673db4:yina/ViewLayer.swift"], cwd=repo, text=True) +
                       "\nextension ViewLayer { func refreshPresentationEligibility() {} }\n")
        sources[-1] = old
    if "--pip-regression-before" in sys.argv:
        old = root / "ViewLayer.swift"
        old.write_text(subprocess.check_output(["git", "show", "62af328e:yina/ViewLayer.swift"], cwd=repo, text=True))
        sources[-1] = old
    subprocess.run(["xcrun", "swiftc", "-D", "IINA_ENABLE_METAL_RENDERER",
                    "-module-cache-path", "/private/tmp/yina-event-module-cache",
                    "-F", "/System/Library/PrivateFrameworks", "-framework", "PIP",
                    "-I", str(repo / "deps/include"), "-import-objc-header", str(header),
                    *map(str, sources), str(repo / "other/tests/paused-metal-resize-smoke.swift"),
                    str(repo / "deps/lib/libmpv.2.dylib"), "-Xlinker", "-rpath", "-Xlinker",
                    str(repo / "deps/lib"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(fixture)] + (["--baseline"] if baseline else []), check=True, timeout=45)
