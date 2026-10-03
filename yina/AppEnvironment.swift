// App-wide persistence policy. A clean start never reads or changes the normal profile.
import Foundation

enum AppEnvironment {
  static let isCleanStart = ProcessInfo.processInfo.arguments.contains("--clean-start")
  private static let sessionID = UUID().uuidString
  static let preferencesDomain = isCleanStart ? "tsmc.yina.clean.\(sessionID)" : (Bundle.main.bundleIdentifier ?? "tsmc.yina")
  static let defaults: UserDefaults = isCleanStart ? UserDefaults(suiteName: preferencesDomain)! : .standard
  static let temporaryRoot: URL? = isCleanStart
    ? FileManager.default.temporaryDirectory.appendingPathComponent("yina-clean-\(sessionID)", isDirectory: true) : nil

  static let importedPreviewDirectoryKey = "iinaImportedPreviewDirectory"

  static var legacyThumbnailCacheURL: URL? {
    guard !isCleanStart else { return nil }
    if let path = defaults.string(forKey: importedPreviewDirectoryKey) {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    // Compatibility for profiles imported before preview migration existed.
    // This is a known cache location, not another installation scan.
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("com.colliderli.iina/thumb_cache", isDirectory: true)
  }

  static var bundledDefaults: [String: Any] {
    guard !isCleanStart else { return [:] }
    guard let url = Bundle.main.url(forResource: "DefaultPreferences", withExtension: "plist"),
          let data = try? Data(contentsOf: url),
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
    return values
  }

  static func prepareCleanStart() {
    guard isCleanStart else { return }
    // AppKit and Sparkle use standard defaults themselves. Override their launch behavior
    // in a volatile domain only, without writing to the user's persistent app settings.
    var launch = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    launch["NSApplicationIgnorePersistentState"] = true
    launch["NSQuitAlwaysKeepsWindows"] = false
    launch["SUEnableAutomaticChecks"] = false
    launch["SUAutomaticallyUpdate"] = false
    UserDefaults.standard.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)
  }

  static func finishCleanStart() {
    guard isCleanStart else { return }
    defaults.removePersistentDomain(forName: preferencesDomain)
    if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
  }
}
