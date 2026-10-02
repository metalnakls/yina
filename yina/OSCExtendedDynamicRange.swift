//
//  OSCExtendedDynamicRange.swift
//  yina
//

import CoreGraphics

enum OSCExtendedDynamicRange {
  static let fallbackHeadroom: CGFloat = 2

  static func luminance(intensity: CGFloat, headroom: CGFloat) -> CGFloat {
    let normalizedIntensity = min(max(intensity, 0), 1)
    return 1 + (max(1, headroom) - 1) * normalizedIntensity
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
