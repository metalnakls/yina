//
//  OSCExtendedDynamicRange.swift
//  yina
//

import AppKit

enum OSCExtendedDynamicRange {
  static let fallbackHeadroom: CGFloat = 2

  static func luminance(intensity: CGFloat, headroom: CGFloat) -> CGFloat {
    let normalizedIntensity = min(max(intensity, 0), 1)
    return 1 + (max(1, headroom) - 1) * normalizedIntensity
  }

  /// Keep semantic hue/alpha and light/dark appearance while matching playback
  /// luminance. Merely tagging a layer as HDR does not brighten SDR colors.
  static func color(_ base: NSColor, headroom: CGFloat) -> NSColor {
    guard headroom.isFinite, headroom > 1 else { return base }
    return NSColor(name: nil) { appearance in
      var resolved: NSColor = base
      appearance.performAsCurrentDrawingAppearance {
        if let rgb = base.usingColorSpace(.sRGB) {
          resolved = NSColor(red: rgb.redComponent, green: rgb.greenComponent,
                             blue: rgb.blueComponent, alpha: rgb.alphaComponent,
                             linearExposure: headroom)
        }
      }
      return resolved
    }
  }

  static func headroom(hdrEnabled: Bool,
                       currentDisplayHeadroom: CGFloat,
                       potentialDisplayHeadroom: CGFloat,
                       renderedContentHeadroom: CGFloat) -> CGFloat {
    guard hdrEnabled else { return 1 }

    let potential = max(1, potentialDisplayHeadroom)
    guard potential > 1 else { return 1 }

    if currentDisplayHeadroom > 1 {
      return min(currentDisplayHeadroom, potential)
    }
    if renderedContentHeadroom > 1 {
      return min(renderedContentHeadroom, potential)
    }
    return min(fallbackHeadroom, potential)
  }
}

/// Promotes owned sidebar controls while retaining their semantic source colors.
/// Weak keys let recycled table cells disappear without retaining their views.
@MainActor
final class PlaybackUIHDRColors {
  private final class SavedColor {
    var original: NSColor?
    var applied: NSColor?
    var headroom: CGFloat
    init(original: NSColor?, applied: NSColor?, headroom: CGFloat) {
      self.original = original; self.applied = applied; self.headroom = headroom
    }
  }
  private let colors = NSMapTable<NSView, SavedColor>(keyOptions: .weakMemory, valueOptions: .strongMemory)

  func apply(to view: NSView, headroom: CGFloat) {
    let current: NSColor?
    let assign: ((NSColor?) -> Void)?
    if let field = view as? NSTextField {
      current = field.textColor
      assign = { field.textColor = $0 }
    } else if let button = view as? NSButton {
      current = button.contentTintColor
      assign = { button.contentTintColor = $0 }
    } else if let image = view as? NSImageView, image.image?.isTemplate == true {
      current = image.contentTintColor
      assign = { image.contentTintColor = $0 }
    } else { current = nil; assign = nil }
    if let assign {
      let previous = colors.object(forKey: view)
      let original = previous != nil && current == previous?.applied ? previous!.original : current
      if previous == nil || previous?.headroom != headroom || current != previous?.applied {
        let applied = headroom > 1 ? OSCExtendedDynamicRange.color(original ?? .labelColor, headroom: headroom) : original
        assign(applied)
        colors.setObject(SavedColor(original: original, applied: applied, headroom: headroom), forKey: view)
      }
    }
    view.subviews.forEach { apply(to: $0, headroom: headroom) }
  }
}
