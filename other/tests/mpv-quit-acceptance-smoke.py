"""Exercise production quit enqueue/retry logic when libmpv rejects one submission."""
from pathlib import Path
import os
import subprocess
import tempfile

source = Path('yina/MPVController.swift').read_text()
method = source[source.index('  func mpvQuit()'):source.index('  // MARK: - Command & property', source.index('  func mpvQuit()'))]
fixture = r'''import Foundation
enum Logger { enum Level { case error } }
enum MPVError: Int32 { case queueFull = -1 }
let MPV_ERROR_EVENT_QUEUE_FULL = MPVError.queueFull
func mpv_unobserve_property(_ pointer: OpaquePointer, _ userdata: UInt64) -> Int32 { 0 }
final class FakeClient {
  var statuses: [Int32] = [-1, 0]
  var submissions = 0
  var flushes = 0
  var invalidations = 0
  func flushLatest() { flushes += 1 }
  func command(_ arguments: [String]) -> Int32 {
    precondition(arguments == ["quit"])
    submissions += 1
    return statuses.removeFirst()
  }
  func invalidate() { invalidations += 1 }
}
final class Controller {
  var mpv: OpaquePointer! = OpaquePointer(bitPattern: 1)
  let asyncClient = FakeClient()
  var quitEnqueuePending = false
  func removeOptionObservers() {}
  func log(_ message: String, level: Logger.Level) { preconditionFailure(message) }
'''+method+r'''
}
@main enum Smoke {
  static func main() {
    let controller = Controller()
    controller.mpvQuit()
    controller.mpvQuit()
    precondition(controller.asyncClient.submissions == 1 && controller.asyncClient.invalidations == 0,
                 "failed quit submission invalidated or duplicated bridge work")
    let deadline = Date().addingTimeInterval(2)
    while controller.asyncClient.invalidations == 0 && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(controller.asyncClient.submissions == 2 && controller.asyncClient.invalidations == 1 &&
                 controller.asyncClient.flushes == 1, "quit retry did not accept exactly once")
    print("PASS: production quit keeps bridge alive for one queue-full retry, then invalidates once")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-quit-acceptance-') as directory:
    path = Path(directory)
    (path/'test.swift').write_text(fixture)
    cache = path/'modules'
    cache.mkdir()
    env = {**os.environ, 'CLANG_MODULE_CACHE_PATH': str(cache), 'SWIFT_MODULE_CACHE_PATH': str(cache)}
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(cache), str(path/'test.swift'), '-o', str(path/'test')], check=True, env=env)
    subprocess.run([str(path/'test')], check=True, timeout=5)
