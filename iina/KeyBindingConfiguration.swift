//
//  KeyBindingConfiguration.swift
//  iina
//
//  Created by IINA on 2026-08-30.
//  Copyright © 2026 lhc. All rights reserved.
//

import Foundation

enum KeyBindingConfiguration {
  static let defaultConfigMap: KeyValuePairs<String, String> = [
    "IINA Default": "iina-default-input",
    "mpv Default": "input",
    "VLC Default": "vlc-default-input",
    "Movist Default": "movist-default-input",
    "Movist v2 Default": "movist-v2-default-input",
  ]

  static let defaultConfigs: [String: String] = {
    Dictionary(uniqueKeysWithValues: defaultConfigMap.map { name, resource in
      (name, Bundle.main.path(forResource: resource, ofType: "conf", inDirectory: "config")!)
    })
  }()

  static var userConfigs: [String: String] {
    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: Utility.userInputConfDirURL,
        includingPropertiesForKeys: nil
      )
      return Dictionary(uniqueKeysWithValues: files
        .filter { $0.pathExtension == "conf" }
        .map { ($0.deletingPathExtension().lastPathComponent, $0.path) })
    } catch {
      Logger.fatal("Cannot get user config file!")
    }
  }
}
