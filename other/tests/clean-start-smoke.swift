// Run the compiled test with --clean-start.
import Foundation
@main struct CleanSmoke {
 static func main() throws {
  precondition(AppEnvironment.isCleanStart)
  precondition(AppEnvironment.bundledDefaults.isEmpty)
  let sentinel = "clean-fixture-\(UUID().uuidString)"
  UserDefaults.standard.set("normal profile", forKey: sentinel)
  defer { UserDefaults.standard.removeObject(forKey: sentinel) }
  precondition(AppEnvironment.defaults.string(forKey: sentinel) == nil)
  AppEnvironment.defaults.set("clean profile", forKey: sentinel)
  precondition(UserDefaults.standard.string(forKey: sentinel) == "normal profile")
  precondition(AppEnvironment.defaults.string(forKey: sentinel) == "clean profile")
  let root = AppEnvironment.temporaryRoot!
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  AppEnvironment.finishCleanStart()
  precondition(!FileManager.default.fileExists(atPath: root.path))
  precondition(AppEnvironment.defaults.persistentDomain(forName: AppEnvironment.preferencesDomain)?.isEmpty != false)
  print("PASS: clean preferences exclude standard settings, writes stay isolated, temporary profile cleans up")
 }
}
