import Cocoa

struct IINAImportProfile {
  let bundleIdentifier: String
  let displayName: String
  let preferences: [String: Any]
  let supportURL: URL

  var thumbnailCacheURL: URL {
    supportURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Caches/\(bundleIdentifier)/thumb_cache", isDirectory: true)
  }
}

/// Detect and import an IINA profile once, before registering YINA's defaults.
final class IdentityMigration {
  static let shared = IdentityMigration()
  static let migrationFlag = "didCheckIINAImport"

  func migrateLegacyIdentityIfNeeded() {
    guard !AppEnvironment.isCleanStart, Bundle.main.bundleIdentifier == "tsmc.yina",
          !AppEnvironment.defaults.bool(forKey: Self.migrationFlag) else { return }

    do {
      try Self.importOnFirstLaunch(defaults: AppEnvironment.defaults,
                                   domain: AppEnvironment.preferencesDomain,
                                   supportURL: Utility.appSupportDirUrl,
                                   discover: { Self.discoverProfiles() },
                                   choose: Self.chooseProfile)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Some IINA data could not be imported"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "Continue")
      alert.runModal()
    }
  }

  static func importOnFirstLaunch(defaults: UserDefaults, domain: String, supportURL: URL,
                                  discover: () -> [IINAImportProfile],
                                  choose: ([IINAImportProfile]) -> IINAImportProfile?) throws {
    guard !defaults.bool(forKey: migrationFlag) else { return }
    // Also record a deliberate skip or no installations, so later launches never scan again.
    defer { defaults.set(true, forKey: migrationFlag) }
    let profiles = discover()
    let chosen = profiles.count > 1 ? choose(profiles) : profiles.first
    if let chosen { try importProfile(chosen, into: defaults, domain: domain, supportURL: supportURL) }
  }

  private static func chooseProfile(_ profiles: [IINAImportProfile]) -> IINAImportProfile? {
    let alert = NSAlert()
    alert.messageText = "Import your IINA settings"
    alert.informativeText = "Choose the IINA installation to import settings, history, and plugins from."
    alert.addButton(withTitle: "Import")
    alert.addButton(withTitle: "Skip")
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
    profiles.forEach { picker.addItem(withTitle: $0.displayName) }
    alert.accessoryView = picker
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn ? profiles[picker.indexOfSelectedItem] : nil
  }

  static func discoverProfiles(
    applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications"),
                                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
    libraryURL: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
  ) -> [IINAImportProfile] {
    let fm = FileManager.default
    let preferencesURL = libraryURL.appendingPathComponent("Preferences", isDirectory: true)
    let supportRoot = libraryURL.appendingPathComponent("Application Support", isDirectory: true)
    var names: [String: Set<String>] = [:]
    for directory in applicationDirectories {
      guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in enumerator {
        guard url.pathExtension == "app" else { continue }
        enumerator.skipDescendants()
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let domain = info["CFBundleIdentifier"] as? String,
              domain != "tsmc.yina",
              ((info["CFBundleExecutable"] as? String)?.lowercased() == "iina" ||
                url.deletingPathExtension().lastPathComponent.lowercased().contains("iina")) else { continue }
        names[domain, default: []].insert(url.path)
      }
    }
    // Include installed profiles even if their app was removed or renamed.
    for url in (try? fm.contentsOfDirectory(at: preferencesURL, includingPropertiesForKeys: nil)) ?? [] {
      let domain = url.deletingPathExtension().lastPathComponent
      if url.pathExtension == "plist", domain.lowercased().contains("iina") {
        names[domain, default: []].insert(domain)
      }
    }
    for url in (try? fm.contentsOfDirectory(at: supportRoot, includingPropertiesForKeys: nil)) ?? [] {
      let domain = url.lastPathComponent
      if domain.lowercased().contains("iina") { names[domain, default: []].insert(domain) }
    }
    names["com.colliderli.iina", default: []].insert("IINA")
    return names.keys.sorted().flatMap { domain -> [IINAImportProfile] in
      let containerLibrary = libraryURL.appendingPathComponent("Containers/\(domain)/Data/Library")
      let preferencePaths = [preferencesURL.appendingPathComponent("\(domain).plist"),
                             containerLibrary.appendingPathComponent("Preferences/\(domain).plist")]
      var preferences: [String: Any] = [:]
      for url in preferencePaths {
        if let data = try? Data(contentsOf: url),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
          preferences = values
          break
        }
      }
      let supportPaths = [supportRoot.appendingPathComponent(domain, isDirectory: true),
                          containerLibrary.appendingPathComponent("Application Support/\(domain)", isDirectory: true)]
      let support = supportPaths.first { fm.fileExists(atPath: $0.path) } ?? supportPaths[0]
      guard !preferences.isEmpty || fm.fileExists(atPath: support.path) else { return [] }
      let installations = names[domain]!.filter { $0.hasSuffix(".app") }.sorted()
      let labels: [String]
      if installations.isEmpty {
        let name = names[domain]!.filter { $0 != domain }.sorted().first ?? domain
        labels = ["\(name) (\(domain))"]
      } else {
        labels = installations.map { path in
          let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
          return "\(name) (\(domain)) — \(path)"
        }
      }
      return labels.map {
        IINAImportProfile(bundleIdentifier: domain, displayName: $0,
                          preferences: preferences, supportURL: support)
      }
    }
  }

  static func importProfile(_ profile: IINAImportProfile, into defaults: UserDefaults,
                            domain: String, supportURL: URL) throws {
    // Check persisted overrides, never registered defaults: defaults must not block an import.
    let existing = defaults.persistentDomain(forName: domain) ?? [:]
    for (key, value) in profile.preferences where existing[key] == nil {
      guard key != migrationFlag, key != "didMigrateFromLegacyBundleID",
            key != AppEnvironment.importedPreviewDirectoryKey,
            !key.hasPrefix("NS"), !key.hasPrefix("SU"), !key.hasPrefix("firstLaunchAfter") else { continue }
      defaults.set(relocate(value, from: profile.supportURL, to: supportURL), forKey: key)
    }
    defaults.set(profile.thumbnailCacheURL.path, forKey: AppEnvironment.importedPreviewDirectoryKey)
    let fm = FileManager.default
    guard fm.fileExists(atPath: profile.supportURL.path) else { return }
    try fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
    try mergeContents(from: profile.supportURL, to: supportURL)
  }

  private static func relocate(_ value: Any, from source: URL, to destination: URL) -> Any {
    if let string = value as? String, string.hasPrefix(source.path + "/") {
      return destination.path + string.dropFirst(source.path.count)
    }
    if let array = value as? [Any] { return array.map { relocate($0, from: source, to: destination) } }
    if let dictionary = value as? [String: Any] {
      return dictionary.mapValues { relocate($0, from: source, to: destination) }
    }
    return value
  }

  private static func mergeContents(from source: URL, to destination: URL) throws {
    let fm = FileManager.default
    for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      // Startup markers and sockets do not belong to the new app identity.
      guard !item.lastPathComponent.hasPrefix(".") else { continue }
      let target = destination.appendingPathComponent(item.lastPathComponent)
      if !fm.fileExists(atPath: target.path) {
        try fm.copyItem(at: item, to: target)
      } else {
        let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var targetIsDirectory: ObjCBool = false
        if values.isDirectory == true, values.isSymbolicLink != true,
           fm.fileExists(atPath: target.path, isDirectory: &targetIsDirectory), targetIsDirectory.boolValue {
          try mergeContents(from: item, to: target)
        }
      }
    }
  }
}
