import Cocoa
import CoreFoundation

/// Applies the curated defaults that are shared across YINA installations.
/// Per-user, per-device, language, and update-channel choices stay local.
final class ManagedDefaultsUpdater {
  static let shared = ManagedDefaultsUpdater()

  private static let schemaVersion = 1
  private static let feedURL = URL(string: "https://raw.githubusercontent.com/metalnakls/yina/meh/yina/ManagedDefaults.json")!
  private static let maxPayloadSize = 64 * 1024
  private static let refreshInterval: TimeInterval = 24 * 60 * 60

  private static let cacheVersionKey = "ManagedDefaultsCacheVersion"
  private static let lastCheckKey = "ManagedDefaultsLastCheck"
  private static let lastAttemptedVersionKey = "ManagedDefaultsLastAttemptedVersion"
  private static let etagKey = "ManagedDefaultsETag"

  private let refreshLock = NSLock()
  private var refreshInProgress = false

  private init() {}

  private static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  private static var baseline: [String: Any] {
    guard let url = Bundle.main.url(forResource: "ManagedDefaults", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          data.count <= maxPayloadSize,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let values = root["defaults"] as? [String: Any],
          let validated = validatedDefaults(in: data, against: values) else { return [:] }
    return validated
  }

  private static var cacheURL: URL {
    Utility.appSupportDirUrl.appendingPathComponent("managed-defaults.json")
  }

  /// Run after the legacy profile import but before registered defaults and settings pages load.
  static func applyStartupDefaults() {
    guard !AppEnvironment.isCleanStart else { return }
    let bundledDefaults = baseline
    guard !bundledDefaults.isEmpty else { return }

    let preferences = UserDefaults.standard
    if preferences.string(forKey: cacheVersionKey) == currentVersion,
       let data = try? Data(contentsOf: cacheURL),
       data.count <= maxPayloadSize,
       let cached = validatedDefaults(in: data, against: bundledDefaults) {
      apply(cached)
      return
    }
    apply(bundledDefaults)
  }

  /// Refresh on launch and activation, with a daily limit unless the app version changed.
  func refreshIfDue() async {
    guard !AppEnvironment.isCleanStart, beginRefresh() else { return }
    defer { endRefresh() }

    let preferences = UserDefaults.standard
    let version = Self.currentVersion
    let versionChanged = preferences.string(forKey: Self.lastAttemptedVersionKey) != version
    if !versionChanged,
       let lastCheck = preferences.object(forKey: Self.lastCheckKey) as? Date,
       Date().timeIntervalSince(lastCheck) < Self.refreshInterval {
      return
    }

    var request = URLRequest(url: Self.feedURL,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 20)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let etag = preferences.string(forKey: Self.etagKey) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse else { return }
      guard response.statusCode == 200 || response.statusCode == 304 else {
        preferences.set(Date(), forKey: Self.lastCheckKey)
        preferences.set(version, forKey: Self.lastAttemptedVersionKey)
        return
      }

      let updateData: Data
      if response.statusCode == 304 {
        guard let cached = try? Data(contentsOf: Self.cacheURL),
              cached.count <= Self.maxPayloadSize else {
          preferences.removeObject(forKey: Self.etagKey)
          preferences.removeObject(forKey: Self.lastCheckKey)
          return
        }
        updateData = cached
      } else {
        guard data.count <= Self.maxPayloadSize else {
          preferences.set(Date(), forKey: Self.lastCheckKey)
          preferences.set(version, forKey: Self.lastAttemptedVersionKey)
          return
        }
        updateData = data
      }

      let currentBaseline = Self.baseline
      guard !currentBaseline.isEmpty,
            let values = Self.validatedDefaults(in: updateData, against: currentBaseline) else {
        preferences.set(Date(), forKey: Self.lastCheckKey)
        preferences.set(version, forKey: Self.lastAttemptedVersionKey)
        return
      }

      await MainActor.run { Self.apply(values) }
      if response.statusCode == 200 {
        try updateData.write(to: Self.cacheURL, options: .atomic)
        if let etag = response.value(forHTTPHeaderField: "ETag") {
          preferences.set(etag, forKey: Self.etagKey)
        } else {
          preferences.removeObject(forKey: Self.etagKey)
        }
      }
      preferences.set(version, forKey: Self.cacheVersionKey)
      preferences.set(version, forKey: Self.lastAttemptedVersionKey)
      preferences.set(Date(), forKey: Self.lastCheckKey)
    } catch {
      preferences.set(version, forKey: Self.lastAttemptedVersionKey)
      preferences.set(Date(), forKey: Self.lastCheckKey)
      // Leave cached and bundled values in place; retry on the next daily check.
      Logger.log("Managed defaults refresh failed.", level: .warning)
    }
  }

  static func exportCurrentSettings() throws -> Data {
    let currentBaseline = baseline
    let values = Dictionary(uniqueKeysWithValues: currentBaseline.keys.sorted().compactMap { key in
      AppEnvironment.defaults.object(forKey: key).map { (key, $0) }
    })
    let payload: [String: Any] = ["schemaVersion": schemaVersion, "defaults": values]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    guard validatedDefaults(in: data, against: currentBaseline) != nil else {
      throw NSError(domain: "ManagedDefaults", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "One or more managed settings have an unsupported value."])
    }
    return data
  }

  private static func apply(_ values: [String: Any]) {
    for (key, value) in values {
      AppEnvironment.defaults.set(value, forKey: key)
    }
  }

  private static func validatedDefaults(in data: Data, against baseline: [String: Any]) -> [String: Any]? {
    guard data.count <= maxPayloadSize,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let schemaValue = root["schemaVersion"] as? NSNumber,
          CFGetTypeID(schemaValue) != CFBooleanGetTypeID(),
          schemaValue.intValue == Self.schemaVersion,
          schemaValue.doubleValue == Double(Self.schemaVersion),
          Set(root.keys) == Set(["schemaVersion", "defaults"]),
          let values = root["defaults"] as? [String: Any],
          !values.isEmpty,
          values.count <= 512 else { return nil }

    var accepted: [String: Any] = [:]
    for (key, value) in values {
      // Older app versions safely ignore keys introduced by a newer release.
      guard let expected = baseline[key] else { continue }
      guard isSupported(value, matching: expected) else { return nil }
      accepted[key] = value
    }
    return accepted.isEmpty ? nil : accepted
  }

  private func beginRefresh() -> Bool {
    refreshLock.lock()
    defer { refreshLock.unlock() }
    guard !refreshInProgress else { return false }
    refreshInProgress = true
    return true
  }

  private func endRefresh() {
    refreshLock.lock()
    refreshInProgress = false
    refreshLock.unlock()
  }

  private static func isSupported(_ value: Any, matching expected: Any) -> Bool {
    if let expectedString = expected as? String {
      guard let valueString = value as? String,
            valueString.utf8.count <= 2_048,
            !valueString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
      return expectedString.utf8.count <= 2_048
    }

    guard let expectedNumber = expected as? NSNumber,
          let valueNumber = value as? NSNumber else { return false }

    if CFGetTypeID(expectedNumber) == CFBooleanGetTypeID() {
      return CFGetTypeID(valueNumber) == CFBooleanGetTypeID()
    }
    guard CFGetTypeID(valueNumber) != CFBooleanGetTypeID() else { return false }
    let number = valueNumber.doubleValue
    guard number.isFinite, abs(number) <= 1_000_000_000 else { return false }
    if !CFNumberIsFloatType(expectedNumber) {
      return number.rounded(.towardZero) == number
    }
    return true
  }
}
