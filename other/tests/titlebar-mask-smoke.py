#!/usr/bin/env python3
"""Raster-check the production alpha mask with synthetic sizes; no app windows."""
import pathlib
import subprocess
import tempfile
source = pathlib.Path("yina/Titlebar.swift").read_text()
start = source.index("  static func progressiveMask(size: NSSize) -> NSImage {")
end = source.index("\n  private func updateShadow()", start)
method = source[start:end]
code = '''import Cocoa
struct Probe {\n''' + method + '''}
for size in [NSSize(width: 640, height: 56), NSSize(width: 1080, height: 64)] {
 let image = Probe.progressiveMask(size: size)
 var rect = NSRect(origin: .zero, size: size)
 let pixels = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
 let x = pixels.pixelsWide / 2
 let top = pixels.colorAt(x: x, y: 0)!.alphaComponent
 let middle = pixels.colorAt(x: x, y: pixels.pixelsHigh / 2)!.alphaComponent
 let bottom = pixels.colorAt(x: x, y: pixels.pixelsHigh - 1)!.alphaComponent
 precondition(top > middle && middle > bottom, "Material must fade progressively toward the video")
 precondition(top < 0.95 && bottom < 0.05, "No opaque slab or hard lower boundary")
}
print("PASS: native-material alpha fades toward the video at multiple window sizes")
'''
with tempfile.TemporaryDirectory(prefix="yina-titlebar-mask-") as directory:
    root = pathlib.Path(directory)
    swift = root / "main.swift"
    binary = root / "probe"
    swift.write_text(code)
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(root / "modules"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
