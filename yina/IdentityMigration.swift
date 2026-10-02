//
//  IdentityMigration.swift
//  yina
//
//  One-time migration of user data from the previous `com.colliderli.iina`
//  application identity to the current `tsmc.yina` identity.
//
//  The bundle identifier determines both the `NSUserDefaults` domain and the
//  `Application Support` directory, so changing it orphans the settings,
//  plugins, watch-later history and input configurations of an existing
//  installation. This copies that data across exactly once, then records a
//  marker so it never runs twice.
//

import Foundation

class IdentityMigration {

  /// Bundle identifier of the application identity this build replaces.
  static let legacyBundleID = "com.colliderli.iina"

  /// Records that the legacy identity has already been imported.
  private static let migrationFlag = "didMigrateFromLegacyBundleID"

  static var shared = IdentityMigration()

  /// Import settings and application support data from the legacy identity.
  ///
  /// Does nothing when the current bundle identifier is not `tsmc.yina`, when
  /// the migration already ran, or when no legacy data exists.
  func migrateLegacyIdentityIfNeeded() {
    let currentBundleID = Bundle.main.bundleIdentifier ?? ""
    guard currentBundleID == "tsmc.yina" else { return }
    // The legacy identity is the app we are replacing, so never import when we
    // are running as that identity itself.
    guard currentBundleID != IdentityMigration.legacyBundleID else { return }
    guard !UserDefaults.standard.bool(forKey: IdentityMigration.migrationFlag) else { return }

    var importedSomething = false
    importedSomething = migratePreferences(from: IdentityMigration.legacyBundleID) || importedSomething
    importedSomething = migrateApplicationSupport(from: IdentityMigration.legacyBundleID) || importedSomething

    // Record the attempt either way: if the legacy data is absent now it will
    // not reappear, and re-running on every launch would be wasteful.
    UserDefaults.standard.set(true, forKey: IdentityMigration.migrationFlag)

    if importedSomething {
      Logger.log("Imported user data from \(IdentityMigration.legacyBundleID)")
    } else {
      Logger.log("No user data to import from \(IdentityMigration.legacyBundleID)")
    }
  }

  /// Copy legacy preference values that the current domain does not define yet.
  ///
  /// Existing values always win so that a migration never overwrites settings
  /// the user has already changed in the new identity.
  private func migratePreferences(from legacyBundleID: String) -> Bool {
    guard let legacy = UserDefaults.standard.persistentDomain(forName: legacyBundleID),
          !legacy.isEmpty else {
      return false
    }
    var didImport = false
    let current = UserDefaults.standard
    for (key, value) in legacy where current.object(forKey: key) == nil {
      current.set(value, forKey: key)
      didImport = true
    }
    return didImport
  }

  /// Copy the legacy `Application Support` directory into the current one.
  ///
  /// Only runs when the current directory is effectively empty, so it can never
  /// overwrite data that the new identity has already created.
  private func migrateApplicationSupport(from legacyBundleID: String) -> Bool {
    let fileManager = FileManager.default
    guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return false
    }
    let legacyURL = support.appendingPathComponent(legacyBundleID, isDirectory: true)
    let currentURL = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "", isDirectory: true)

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: legacyURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return false
    }

    // The current directory is created eagerly during startup, so treat a
    // directory that holds nothing but our own scaffolding as empty.
    let existing = (try? fileManager.contentsOfDirectory(atPath: currentURL.path)) ?? []
    let meaningful = existing.filter { entry in
      // These are recreated on every launch and carry no user data.
      !entry.hasPrefix(".") && entry != AppData.pluginsFolder
        && entry != AppData.userInputConfFolder && entry != AppData.watchLaterFolder
        && entry != AppData.binariesFolder
    }
    guard meaningful.isEmpty else { return false }

    do {
      try fileManager.createDirectory(at: currentURL, withIntermediateDirectories: true)
      for entry in try fileManager.contentsOfDirectory(at: legacyURL, includingPropertiesForKeys: nil) {
        let destination = currentURL.appendingPathComponent(entry.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
          try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: entry, to: destination)
      }
      return true
    } catch {
      Logger.log("Failed to import application support data: \(error.localizedDescription)", level: .error)
      return false
    }
  }
}
