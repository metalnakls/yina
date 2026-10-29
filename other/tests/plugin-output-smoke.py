"""Exercise the production pipe collector with noisy and finite subprocesses."""
from pathlib import Path
import os
import subprocess
import tempfile

source = Path('yina/JavascriptAPIUtils.swift').read_text()
start = source.index('      let group = DispatchGroup()')
end = source.index('      Logger.log("Executing', start)
capture = source[start:end]
fixture = r'''import Foundation
final class JSValue {
  var isObject = true
  func call(withArguments: [String]) {}
}
final class Harness {
  var pluginInstance: NSObject? = NSObject()
  func run(_ shell: String, limit maxOutputBytes: Int?) throws -> (String, String, Int, Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", shell]
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let stdoutURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stderrURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdoutFile = try FileHandle(forWritingTo: stdoutURL)
    let stderrFile = try FileHandle(forWritingTo: stderrURL)
    let stdoutHook_: JSValue? = nil, stderrHook_: JSValue? = nil
'''+capture+r'''
    try process.run()
    precondition(group.wait(timeout: .now() + 10) == .success, "pipe EOF or process exit did not arrive")
    try stdoutFile.close(); try stderrFile.close()
    let out = try String(contentsOf: stdoutURL, encoding: .utf8)
    let err = try String(contentsOf: stderrURL, encoding: .utf8)
    try FileManager.default.removeItem(at: stdoutURL)
    try FileManager.default.removeItem(at: stderrURL)
    return (out, err, outputBytes, exceededLimit)
  }
}
@main enum Smoke {
  static func main() throws {
    let harness = Harness()
    let (out, err, _, exceeded) = try harness.run("printf out; printf err >&2", limit: nil)
    precondition(out == "out" && err == "err" && !exceeded, "stream data changed")
    let (large, _, count, over) = try harness.run("yes x | head -c 1048576", limit: 4096)
    precondition(over && count > 4096 && large.utf8.count <= 4096, "limit did not bound captured output")
    print("PASS: production collector drains both pipes and rejects output over the explicit limit")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-plugin-output-') as directory:
    path = Path(directory)
    (path/'test.swift').write_text(fixture)
    cache = path/'module-cache'
    cache.mkdir()
    env = {**os.environ, 'CLANG_MODULE_CACHE_PATH': str(cache), 'SWIFT_MODULE_CACHE_PATH': str(cache)}
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(cache), str(path/'test.swift'), '-o', str(path/'test')], check=True, env=env)
    subprocess.run([str(path/'test')], check=True, timeout=20)
