// xcrun swiftc -module-cache-path /tmp/yina-test-modules yina/AppEnvironment.swift \
//   yina/IdentityMigration.swift other/tests/identity-import-smoke.swift -o /tmp/yina-import-smoke
import Cocoa

// Storage fixture: the test never touches the user's application support directory.
enum Utility { static let appSupportDirUrl = FileManager.default.temporaryDirectory.appendingPathComponent("unused-yina-import-test") }

@main struct IdentityImportSmoke {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("yina-import-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    let preferences = library.appendingPathComponent("Preferences")
    let applications = root.appendingPathComponent("Applications")
    try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
    try fm.createDirectory(at: applications, withIntermediateDirectories: true)
    func seed(_ domain: String, _ name: String) throws {
      let contents = applications.appendingPathComponent("\(name).app/Contents")
      try fm.createDirectory(at: contents, withIntermediateDirectories: true)
      let info = ["CFBundleIdentifier": domain, "CFBundleExecutable": "IINA"]
      try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
      let support = library.appendingPathComponent("Application Support/\(domain)/input_conf")
      try fm.createDirectory(at: support, withIntermediateDirectories: true)
      try Data("source input".utf8).write(to: support.appendingPathComponent("custom.conf"))
      let values: [String: Any] = ["volume": 85, "themeMaterial": 1,
                                 "customPath": support.appendingPathComponent("custom.conf").path,
                                 "savedServers": ["fixture-server"], "SUFeedURL": "ignored"]
      try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        .write(to: preferences.appendingPathComponent("\(domain).plist"))
    }
    precondition(IdentityMigration.discoverProfiles(applicationDirectories: [applications], libraryURL: library).isEmpty)
    try seed("com.colliderli.iina", "IINA")
    var profiles = IdentityMigration.discoverProfiles(applicationDirectories: [applications], libraryURL: library)
    precondition(profiles.count == 1)
    try seed("test.iina.nightly", "IINA Nightly")
    profiles = IdentityMigration.discoverProfiles(applicationDirectories: [applications], libraryURL: library)
    precondition(profiles.count == 2)
    try seed("com.colliderli.iina", "IINA Copy")
    profiles = IdentityMigration.discoverProfiles(applicationDirectories: [applications], libraryURL: library)
    precondition(profiles.count == 3) // Distinguish app copies even when they share a settings domain.
    let domain = "test.yina.import.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.register(defaults: ["volume": 100, "themeMaterial": 0])
    defaults.set(2, forKey: "themeMaterial")
    let destination = root.appendingPathComponent("destination")
    try fm.createDirectory(at: destination.appendingPathComponent("input_conf"), withIntermediateDirectories: true)
    try Data("keep destination".utf8).write(to: destination.appendingPathComponent("input_conf/keep.conf"))
    try IdentityMigration.importProfile(profiles[0], into: defaults, domain: domain, supportURL: destination)
    precondition(defaults.string(forKey: AppEnvironment.importedPreviewDirectoryKey) == profiles[0].thumbnailCacheURL.path)
    precondition(defaults.integer(forKey: "volume") == 85) // Registered defaults must not block import.
    precondition(defaults.integer(forKey: "themeMaterial") == 2) // Existing user choices win.
    precondition(defaults.stringArray(forKey: "savedServers") == ["fixture-server"])
    precondition(defaults.object(forKey: "SUFeedURL") == nil)
    precondition(defaults.string(forKey: "customPath") == destination.appendingPathComponent("input_conf/custom.conf").path)
    let kept = try String(contentsOf: destination.appendingPathComponent("input_conf/keep.conf"), encoding: .utf8)
    precondition(kept == "keep destination")
    precondition(fm.fileExists(atPath: destination.appendingPathComponent("input_conf/custom.conf").path))
    try Data("new destination".utf8).write(to: destination.appendingPathComponent("input_conf/custom.conf"))
    try IdentityMigration.importProfile(profiles[0], into: defaults, domain: domain, supportURL: destination)
    let merged = try String(contentsOf: destination.appendingPathComponent("input_conf/custom.conf"), encoding: .utf8)
    precondition(merged == "new destination")
    var scans = 0
    var prompts = 0
    for count in 0...2 {
      defaults.removeObject(forKey: IdentityMigration.migrationFlag)
      let subset = Array(profiles.prefix(count))
      let scansBefore = scans
      let promptsBefore = prompts
      for _ in 0..<2 {
        try IdentityMigration.importOnFirstLaunch(defaults: defaults, domain: domain, supportURL: destination,
          discover: { scans += 1; return subset },
          choose: { options in prompts += 1; return options.last })
      }
      precondition(scans == scansBefore + 1)
      precondition(prompts == promptsBefore + (count > 1 ? 1 : 0))
    }
    defaults.removeObject(forKey: IdentityMigration.migrationFlag)
    try IdentityMigration.importOnFirstLaunch(defaults: defaults, domain: domain, supportURL: destination,
      discover: { profiles }, choose: { _ in nil })
    precondition(defaults.bool(forKey: IdentityMigration.migrationFlag))
    print("PASS: one-time scans, multiple-profile chooser, skip, imported defaults and servers, relocated configs, safe merge, preserved user overrides")
  }
}
