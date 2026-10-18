//
//  SubtitleStyles.swift
//  yina
//
//  Copyright © 2026 lhc. All rights reserved.
//

import AppKit

// MARK: - Subtitle style

/// A named subtitle look.
///
/// A style is not a partial tweak. Selecting one rewrites every appearance preference listed in
/// `SubtitleStyles.ownedKeys` and raises mpv's `sub-ass-override` to `force`, so the styling
/// baked into the subtitle file itself is discarded. `SubtitleStyleID.none` is the escape hatch:
/// it restores YINA's shipped defaults and lets every subtitle file style itself.
///
/// - Important: Raw values are persisted. Never renumber an existing case.
enum SubtitleStyleID: Int, InitializingFromKey, CaseIterable {
  case bitchy = 0
  case classicYellow
  case whiteOnBlack
  case netflix
  case beefy
  case none

  static var defaultValue: SubtitleStyleID { .bitchy }

  init?(key: Preference.Key) {
    self.init(rawValue: Preference.integer(for: key))
  }

  var description: String { id }

  /// Stable slug. Used in log messages only; the preference stores the raw value.
  var id: String {
    switch self {
    case .bitchy: "bitchy"
    case .classicYellow: "classicYellow"
    case .whiteOnBlack: "whiteOnBlack"
    case .netflix: "netflix"
    case .beefy: "beefy"
    case .none: "none"
    }
  }

  var localizedName: String {
    NSLocalizedString("settings.subStyle.items.\(rawValue)", comment: "")
  }
}

// MARK: - Subtitle style profile

/// The appearance one style writes.
///
/// A `nil` member means the profile leaves that preference alone. Every profile that ships with
/// YINA fills in all of them; the `nil` cases exist so a future style can opt out of one knob
/// without having to spell out a value.
struct SubtitleStyleProfile {
  let id: SubtitleStyleID
  let font: String?
  let size: Float?
  let bold: Bool?
  let italic: Bool?
  let textColor: String?
  let blur: Float?
  let spacing: Float?
  let outlineSize: Float?
  let outlineColor: String?
  let shadowSize: Float?
  let shadowColor: String?
  let borderStyle: Preference.SubBorderStyle?

  init(id: SubtitleStyleID, font: String? = nil, size: Float? = nil, bold: Bool? = nil,
       italic: Bool? = nil, textColor: String? = nil, blur: Float? = nil, spacing: Float? = nil,
       outlineSize: Float? = nil, outlineColor: String? = nil, shadowSize: Float? = nil,
       shadowColor: String? = nil, borderStyle: Preference.SubBorderStyle? = nil) {
    self.id = id
    self.font = font
    self.size = size
    self.bold = bold
    self.italic = italic
    self.textColor = textColor
    self.blur = blur
    self.spacing = spacing
    self.outlineSize = outlineSize
    self.outlineColor = outlineColor
    self.shadowSize = shadowSize
    self.shadowColor = shadowColor
    self.borderStyle = borderStyle
  }

  /// Write this profile into preferences.
  ///
  /// This only touches preferences: the `MPVController` option observers push each write straight
  /// into mpv, so applying a style restyles every open player window without any extra plumbing.
  func apply() {
    if let font { Preference.set(font, for: .subTextFont) }
    if let size { Preference.set(size, for: .subTextSize) }
    if let bold { Preference.set(bold, for: .subBold) }
    if let italic { Preference.set(italic, for: .subItalic) }
    if let textColor { Preference.set(textColor, for: .subTextColorString) }
    if let blur { Preference.set(blur, for: .subBlur) }
    if let spacing { Preference.set(spacing, for: .subSpacing) }
    if let outlineSize { Preference.set(outlineSize, for: .subBorderSize) }
    if let outlineColor { Preference.set(outlineColor, for: .subBorderColorString) }
    if let shadowSize { Preference.set(shadowSize, for: .subShadowSize) }
    if let shadowColor { Preference.set(shadowColor, for: .subShadowColorString) }
    if let borderStyle { Preference.set(borderStyle.rawValue, for: .subBorderStyle) }
  }
}

// MARK: - Subtitle styles

enum SubtitleStyles {
  /// The appearance preferences a style owns.
  ///
  /// Applying a style overwrites every key in here — that is what makes a style a *complete*
  /// override rather than a partial tweak. Applying `SubtitleStyleID.none` restores YINA's shipped
  /// value for each.
  static let ownedKeys: [Preference.Key] = [
    .subTextFont, .subTextSize, .subBold, .subItalic, .subTextColorString, .subBlur, .subSpacing,
    .subBorderSize, .subBorderColorString, .subShadowSize, .subShadowColorString, .subBorderStyle,
    .subOverrideLevel, .secondarySubOverrideLevel,
  ]

  /// The `sub-ass-override` level that makes a style a complete override: every `sub-*` option
  /// above is applied instead of the subtitle file's own styling.
  static let completeOverride: Preference.SubOverrideLevel = .force

  static let profiles: [SubtitleStyleID: SubtitleStyleProfile] = [
    // Serif white with no outline, a touch of blur and a small shadow. Subtle on purpose.
    .bitchy: .init(id: .bitchy, font: "AppleGaramond", size: 42, bold: false, italic: false,
                   textColor: mpvColor(0xFFFFFF), blur: 0.42, spacing: 0,
                   outlineSize: 0, outlineColor: mpvColor(0xFFFFFF),
                   shadowSize: 0.2, shadowColor: mpvColor(0x000000, alpha: 0),
                   borderStyle: .outlineAndShadow),

    // The DVD/broadcast look: yellow text with a black outline and nothing else.
    .classicYellow: .init(id: .classicYellow, font: "Helvetica", size: 42, bold: false, italic: false,
                          textColor: mpvColor(0xFFFF54), blur: 0, spacing: 0,
                          outlineSize: 2.5, outlineColor: mpvColor(0x000000),
                          shadowSize: 0, shadowColor: mpvColor(0x000000, alpha: 0),
                          borderStyle: .outlineAndShadow),

    // White on a fully opaque black box. Maximum legibility, minimum taste.
    .whiteOnBlack: .init(id: .whiteOnBlack, font: "Helvetica", size: 42, bold: false, italic: false,
                         textColor: mpvColor(0xFFFFFF), blur: 0, spacing: 0,
                         outlineSize: 0, outlineColor: mpvColor(0x000000),
                         shadowSize: 0, shadowColor: mpvColor(0x000000),
                         borderStyle: .opaqueBox),

    // Streaming-service look: near-white text, a soft dark edge instead of a hard black one,
    // and a light shadow so subtitles sit on top of bright footage.
    .netflix: .init(id: .netflix, font: "Helvetica Neue", size: 40, bold: false, italic: false,
                    textColor: mpvColor(0xFFFFFF), blur: 0.3, spacing: 0,
                    outlineSize: 1.2, outlineColor: mpvColor(0x1A1A1A),
                    shadowSize: 0.6, shadowColor: mpvColor(0x000000, alpha: 0.55),
                    borderStyle: .outlineAndShadow),

    // Big, bold, and outlined hard enough to read over anything.
    .beefy: .init(id: .beefy, font: "Helvetica Neue", size: 58, bold: true, italic: false,
                  textColor: mpvColor(0xFFFFFF), blur: 0, spacing: 0,
                  outlineSize: 4.5, outlineColor: mpvColor(0x000000),
                  shadowSize: 1.2, shadowColor: mpvColor(0x000000, alpha: 0.85),
                  borderStyle: .outlineAndShadow),
  ]

  static func profile(for id: SubtitleStyleID) -> SubtitleStyleProfile? {
    profiles[id]
  }

  /// Select `id` and restyle subtitles.
  ///
  /// Writes `subStyle`; the observer in `MPVController` reacts by calling `push`. Returns the
  /// applied profile, or `nil` for `none`.
  @discardableResult
  static func apply(_ id: SubtitleStyleID) -> SubtitleStyleProfile? {
    Preference.set(id.rawValue, for: .subStyle)
    return push(id)
  }

  /// Write `id`'s appearance into preferences.
  ///
  /// Deliberately does not write `subStyle`: that key is what drives this method, so writing it
  /// back here would re-trigger the observer forever.
  @discardableResult
  static func push(_ id: SubtitleStyleID) -> SubtitleStyleProfile? {
    guard let profile = profiles[id] else {
      // `none` is a style in its own right: no override, restore YINA's shipped look.
      restoreDefaults()
      return nil
    }
    // Apply the complete-override level first so the profile's own values are the ones libass
    // ends up honouring.
    Preference.set(completeOverride.rawValue, for: .subOverrideLevel)
    Preference.set(completeOverride.rawValue, for: .secondarySubOverrideLevel)
    profile.apply()
    return profile
  }

  private static func restoreDefaults() {
    for key in ownedKeys {
      guard let value = Preference.defaultPreference[key] else { continue }
      Preference.set(value, for: key)
    }
  }

  /// Build an mpv `r/g/b/a` color string from a packed `0xRRGGBB` value.
  private static func mpvColor(_ hex: UInt32, alpha: Double = 1) -> String {
    let red = Double((hex >> 16) & 0xFF) / 255
    let green = Double((hex >> 8) & 0xFF) / 255
    let blue = Double(hex & 0xFF) / 255
    return "\(red)/\(green)/\(blue)/\(alpha)"
  }

  // MARK: - Preview

  /// A snapshot of the live subtitle appearance.
  ///
  /// The style preview draws from the preferences rather than from a profile, so it stays truthful
  /// when a style leaves a knob alone — and so it doubles as a live preview of the font, colour,
  /// outline and shadow controls next to it.
  struct Preview {
    let font: NSFont
    let textColor: NSColor
    let outlineColor: NSColor
    let outlineSize: CGFloat
    let shadowColor: NSColor
    let shadowSize: CGFloat
    let isBox: Bool

    /// mpv sizes subtitles relative to the video height; scale that down to something that fits
    /// in a sidebar row without pretending to be pixel-accurate.
    static let pointSizeScale = 0.62

    static func current() -> Preview {
      let size = CGFloat(Preference.float(for: .subTextSize)) * pointSizeScale
      var traits: NSFontDescriptor.SymbolicTraits = []
      if Preference.bool(for: .subBold) { traits.insert(.bold) }
      if Preference.bool(for: .subItalic) { traits.insert(.italic) }

      let fontName = Preference.string(for: .subTextFont) ?? ""
      let base = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
      let font: NSFont
      if traits.isEmpty {
        font = base
      } else {
        font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
      }

      let borderStyle: Preference.SubBorderStyle = Preference.enum(for: .subBorderStyle)
      return Preview(font: font,
                     textColor: color(for: .subTextColorString, fallback: .white),
                     outlineColor: color(for: .subBorderColorString, fallback: .black),
                     outlineSize: CGFloat(Preference.float(for: .subBorderSize)),
                     shadowColor: color(for: .subShadowColorString, fallback: .clear),
                     shadowSize: CGFloat(Preference.float(for: .subShadowSize)),
                     isBox: borderStyle != .outlineAndShadow)
    }

    private static func color(for key: Preference.Key, fallback: NSColor) -> NSColor {
      guard let string = Preference.string(for: key), let color = NSColor(mpvColorString: string) else {
        return fallback
      }
      return color
    }
  }
}