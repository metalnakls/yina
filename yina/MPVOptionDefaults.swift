//
//  MPVDefaults.swift
//  yina
//
//  Created by low-batt on 10/24/24.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation

/// A separate mpv core supplies option defaults and library versions. Its
/// entire lifetime and all libmpv calls belong to the private utility queue.
/// Synchronous getters only consult the cache; a miss schedules a query and
/// returns nil, which affects optional startup logging but not option values.
final class MPVOptionDefaults {
  static let shared = MPVOptionDefaults()

  private enum Kind: Hashable { case double, flag, integer, string, mpvVersion, libassVersion }
  private struct Key: Hashable { let name: String; let kind: Kind }
  private enum Value {
    case double(Double), flag(Bool), integer(Int), string(String)
  }

  private let queue = DispatchQueue(label: "tsmc.yina.mpv-defaults", qos: .utility)
  private let lock = NSLock()
  private var cache: [Key: Value] = [:]
  private var resolved = Set<Key>()
  private var scheduled = Set<Key>()
  // Queue-confined. The singleton retains this core for process lifetime.
  private var core: OpaquePointer?
  private var initializationAttempted = false

  private init() {}

  var mpvVersion: String {
    stringValue(cached(Key(name: MPVProperty.mpvVersion, kind: .mpvVersion))) ?? "Loading mpv version…"
  }

  var libassVersion: String {
    stringValue(cached(Key(name: MPVProperty.libassVersion, kind: .libassVersion))) ?? "Loading libass version…"
  }

  func getDouble(_ name: String) -> Double? {
    guard case .double(let value) = cached(Key(name: name, kind: .double)) else { return nil }
    return value
  }

  func getFlag(_ name: String) -> Bool? {
    guard case .flag(let value) = cached(Key(name: name, kind: .flag)) else { return nil }
    return value
  }

  func getInt(_ name: String) -> Int? {
    guard case .integer(let value) = cached(Key(name: name, kind: .integer)) else { return nil }
    return value
  }

  func getString(_ name: String) -> String? {
    stringValue(cached(Key(name: name, kind: .string)))
  }

  /// Completes on the main queue with the actual default, or nil on failure.
  func getDefaultString(_ name: String, completion: @escaping (String?) -> Void) {
    request(Key(name: name, kind: .string)) { completion(self.stringValue($0)) }
  }

  /// Completes on the main queue after both library versions have been read.
  func getVersions(completion: @escaping (String?, String?) -> Void) {
    request(Key(name: MPVProperty.mpvVersion, kind: .mpvVersion)) { [self] mpvValue in
      request(Key(name: MPVProperty.libassVersion, kind: .libassVersion)) { libassValue in
        completion(self.stringValue(mpvValue), self.stringValue(libassValue))
      }
    }
  }

  private func stringValue(_ value: Value?) -> String? {
    guard case .string(let result) = value else { return nil }
    return result
  }

  private func cached(_ key: Key) -> Value? {
    lock.lock()
    let value = cache[key]
    let shouldSchedule = !resolved.contains(key) && scheduled.insert(key).inserted
    lock.unlock()
    if shouldSchedule { request(key) { _ in } }
    return value
  }

  private func request(_ key: Key, completion: @escaping (Value?) -> Void) {
    queue.async { [self] in
      lock.lock()
      let wasResolved = resolved.contains(key)
      var value = cache[key]
      lock.unlock()
      if !wasResolved {
        value = read(key)
        lock.lock()
        cache[key] = value
        resolved.insert(key)
        scheduled.remove(key)
        lock.unlock()
      }
      let result = value
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// Only called on `queue`.
  private func ensureCore() -> OpaquePointer? {
    if initializationAttempted { return core }
    initializationAttempted = true
    guard let handle = mpv_create() else {
      Self.log("Failed to create a mpv instance", level: .error)
      return nil
    }
    for name in [MPVOption.ProgramBehavior.loadAutoProfiles, MPVOption.ProgramBehavior.loadCommands,
                 MPVOption.ProgramBehavior.loadConsole, MPVOption.ProgramBehavior.loadContextMenu,
                 MPVOption.ProgramBehavior.loadPositioning, MPVOption.ProgramBehavior.loadScripts,
                 MPVOption.ProgramBehavior.loadSelect, MPVOption.ProgramBehavior.loadStatsOverlay] {
      logError(mpv_set_option_string(handle, name, "no"))
    }
    guard logError(mpv_initialize(handle)) >= 0 else {
      mpv_terminate_destroy(handle)
      return nil
    }
    core = handle
    return handle
  }

  /// Only called on `queue`; values are copied before leaving libmpv.
  private func read(_ key: Key) -> Value? {
    guard let handle = ensureCore() else { return nil }
    let name: String
    switch key.kind {
    case .mpvVersion, .libassVersion: name = key.name
    default: name = "option-info/\(key.name)/default-value"
    }
    switch key.kind {
    case .double:
      var value = Double()
      guard logError(mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)) >= 0 else { return nil }
      return .double(value)
    case .flag:
      var value: Int32 = 0 // MPV_FORMAT_FLAG writes an int, not int64_t.
      guard logError(mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)) >= 0 else { return nil }
      return .flag(value != 0)
    case .integer, .libassVersion:
      var value: Int64 = 0
      guard logError(mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)) >= 0 else { return nil }
      if key.kind == .libassVersion {
        return .string("\(String(value >> 28 & 0xF, radix: 16)).\(String(value >> 20 & 0xFF, radix: 16)).\(String(value >> 12 & 0xFF, radix: 16))")
      }
      return .integer(Int(value))
    case .string, .mpvVersion:
      guard let value = mpv_get_property_string(handle, name) else { return nil }
      defer { mpv_free(value) }
      return .string(String(cString: value))
    }
  }

  @discardableResult
  private func logError(_ errorCode: Int32) -> Int32 {
    guard errorCode < 0 else { return errorCode }
    Self.log("mpv API error: \"\(String(cString: mpv_error_string(errorCode)))\", Return value: \(errorCode)", level: .error)
    return errorCode
  }

  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.mpvDefaults)
  }
}

extension Logger.Sub {
  static let mpvDefaults = Logger.makeSubsystem("mpv-defaults")
}
