#!/usr/bin/env python3
"""Native color/layer checks for playback overlays, without opening the app."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
extensions = (root / 'yina/Extensions.swift').read_text()
start = extensions.index('extension NSView {\n  func setOwnExtendedDynamicRange')
end = extensions.index('\nextension Data {', start)
layer_helpers = extensions[start:end]
# Layout is outside this test; use a no-op at that boundary so the production
# material rebuilding and layer configuration are exercised without app state.
stubs = '''
enum Edge { case all; case horizontal(CGFloat); case vertical(CGFloat) }
extension NSView { func padding(_ edges: Edge...) {} }
'''
checks = '''
@main struct HDRSmoke {
  @MainActor static func main() {
    _ = NSApplication.shared
    for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
      let appearance = NSAppearance(named: name)!
      appearance.performAsCurrentDrawingAppearance {
        for base in [NSColor.labelColor, .secondaryLabelColor, .controlAccentColor, .white.withAlphaComponent(0.4)] {
          let hdr = OSCExtendedDynamicRange.color(base, headroom: 4)
          precondition(abs(hdr.cgColor.contentHeadroom - 4) < 0.01, "SDR color on HDR overlay")
          precondition(abs(hdr.alphaComponent - base.alphaComponent) < 0.01, "Lost semantic alpha")
          let sdr = OSCExtendedDynamicRange.color(base, headroom: 1)
          precondition(sdr == base, "SDR appearance not restored")
        }
        let white = OSCExtendedDynamicRange.color(.white, headroom: 4)
        precondition(white.usingColorSpace(.extendedSRGB)!.redComponent > 1, "HDR output clipped")
      }
    }
    let palette = PlaybackUIHDRColors()
    let root = NSView()
    let label = NSTextField(labelWithString: "Episode")
    label.textColor = .secondaryLabelColor
    root.addSubview(label)
    palette.apply(to: root, headroom: 4)
    precondition(label.textColor!.cgColor.contentHeadroom == 4)
    palette.apply(to: root, headroom: 2)
    precondition(label.textColor!.cgColor.contentHeadroom == 2)
    // A reused cell may change its semantic role between layout passes.
    label.textColor = .systemRed
    palette.apply(to: root, headroom: 2)
    palette.apply(to: root, headroom: 1)
    precondition(label.textColor == .systemRed, "Reused cell lost its source color")
    let button = NSButton(title: "Follow", target: nil, action: nil)
    root.addSubview(button)
    palette.apply(to: root, headroom: 4)
    precondition(button.contentTintColor!.cgColor.contentHeadroom == 4)
    palette.apply(to: root, headroom: 1)
    precondition(button.contentTintColor == nil, "Native button tint not restored")
    for placement in [TranslucentView.ContentPlacement.insideMaterial, .aboveMaterial] {
      let view = TranslucentView(padding: (0, 0), contentPlacement: placement)
      let content = NSView()
      let text = NSTextField(labelWithString: "Paused")
      content.addSubview(text)
      view.setContent(content)
      view.setContentExtendedDynamicRange(true, headroom: 4)
      for style in [TranslucentView.Style.visualEffect, .liquidGlass, .visualEffect] {
        view.setStyle(style, force: true)
        precondition(text.layer?.preferredDynamicRange == .high)
        precondition(text.layer?.contentsFormat == .RGBA16Float)
        precondition(text.layer?.contentsHeadroom == 4)
        precondition(view.container?.layer?.preferredDynamicRange == .high)
        precondition(content.superview != nil)
      }
      view.setContentExtendedDynamicRange(false, headroom: 1)
      precondition(text.layer?.preferredDynamicRange == .standard)
      precondition(text.layer?.contentsFormat == .RGBA8Uint)
      precondition(text.layer?.contentsHeadroom == 1)
    }
    print("PASS: semantic HDR colors in four appearances; alpha/SDR restoration; both material placements retain HDR through rebuilds")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-ui-hdr-') as d:
    d = Path(d)
    source = d / 'Fixture.swift'
    source.write_text('import Cocoa\n' + stubs + layer_helpers + (root / 'yina/TranslucentView.swift').read_text() + checks)
    binary = d / 'fixture'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', '/tmp/yina-hdr-modules',
                    str(root / 'yina/OSCExtendedDynamicRange.swift'), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
