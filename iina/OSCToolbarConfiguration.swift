//
//  OSCToolbarConfiguration.swift
//  iina
//
//  Created by IINA on 2026-08-30.
//  Copyright © 2026 lhc. All rights reserved.
//

enum OSCToolbarConfiguration {
  static var buttons: [Preference.ToolBarButton] {
    (Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? [])
      .compactMap(Preference.ToolBarButton.init(rawValue:))
  }

  static var items: [Preference.ToolBarButton] {
    var items = buttons
    if Preference.bool(for: .showOSCVolumeControls) {
      items.insert(.volume, at: 0)
    }
    return items
  }

  static func save(_ items: [Preference.ToolBarButton]) {
    Preference.set(items.contains(.volume), for: .showOSCVolumeControls)
    Preference.set(items.filter { $0 != .volume }.map(\.rawValue), for: .controlBarToolbarButtons)
  }
}
