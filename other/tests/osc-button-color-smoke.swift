import Cocoa
import CoreImage

enum Preference {
  enum Key { case disableAnimations }
  static func bool(for key: Key) -> Bool { true }
}

@main struct OSCButtonColorSmoke {
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      for headroom: CGFloat in [1, 4] {
        let native = draw(role: .standard, appearance: appearanceName, headroom: headroom)
        let transport = draw(role: .transport, appearance: appearanceName, headroom: headroom)
        print("\(appearanceName.rawValue) headroom=\(headroom): native=\(native) transport=\(transport)")
        fflush(stdout)
        precondition(native >= transport * 0.95, "Native play glyph must match transport white")
      }
    }
    print("PASS: native play glyph matches transport white in light/dark and SDR/HDR drawing")
  }

  static func draw(role: OSCButton.Role, appearance: NSAppearance.Name, headroom: CGFloat) -> Float {
    let button = OSCButton(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    button.appearance = NSAppearance(named: appearance)
    button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    button.setQuickTimeStyle(true, role: role)
    button.extendedDynamicRangeHeadroom = headroom
    var pixels = [Float](repeating: 0, count: 64 * 64 * 4)
    pixels.withUnsafeMutableBytes { storage in
      let cg = CGContext(data: storage.baseAddress, width: 64, height: 64,
        bitsPerComponent: 32, bytesPerRow: 64 * 16,
        space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue |
          CGImageAlphaInfo.premultipliedLast.rawValue)!
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
      button.effectiveAppearance.performAsCurrentDrawingAppearance { button.draw(button.bounds) }
      NSGraphicsContext.restoreGraphicsState()
    }
    // Ignore alpha; only compare the brightest glyph RGB samples.
    return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.max()!
  }
}
