#!/usr/bin/env python3
"""Drive the production display/HDR refresh with a deliberately stalled engine."""
import pathlib
import re
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/VideoView.swift").read_text()
def method(signature):
    start = source.index("  " + signature)
    return source[start:source.index("\n  }", start) + len("\n  }")]
hdr = source[source.index("// MARK: - HDR"):source.index("\n#if !IINA_ENABLE_METAL_RENDERER\nfileprivate func displayLinkCallback")]
production = "\nextension VideoView {\n" + method("func updateDisplayLink(") + "\n" + method("private func setICCProfile(") + "\n}\n" + hdr
names = sorted(set(re.findall(r"MPVOption\.GPURendererOptions\.(\w+)", production)))
options = (repo / "yina/MPVOption.swift").read_text()
constants = []
for name in names:
    constants.append(re.search(r"static let " + name + r' = "[^"]+"', options).group())
fixture = (repo / "other/tests/wake-display-refresh-smoke.swift").read_text()
fixture = fixture.replace("// GPU_OPTIONS", "\n".join(constants))
with tempfile.TemporaryDirectory(prefix="yina-wake-display-") as directory:
    root = pathlib.Path(directory)
    swift = root / "fixture.swift"
    swift.write_text(fixture + production)
    binary = root / "refresh"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-D", "IINA_ENABLE_METAL_RENDERER",
                    "-module-cache-path", "/private/tmp/yina-event-module-cache",
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
