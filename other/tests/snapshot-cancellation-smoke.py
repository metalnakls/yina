#!/usr/bin/env python3
"""Exercise the production SnapshotRequest and capture cancellation lifecycle."""
from pathlib import Path
import os
import subprocess
import tempfile

source = Path('yina/ViewLayer.swift').read_text()
start = source.index('  private final class SnapshotRequest:')
end = source.index('  private weak var videoView:', start)
request = source[start:end].replace('private final class SnapshotRequest:', 'final class SnapshotRequest:', 1)
start = source.index('  func captureSnapshot() async -> NSImage?')
end = source.index('  func setRenderICCProfile(', start)
methods = source[start:end]
fixture = r'''import Cocoa
import Foundation

final class Lock {
  private let lock = NSLock()
  func withLock<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body()
  }
}
'''+request+r'''
final class SnapshotHarness: @unchecked Sendable {
  let snapshotLock = Lock()
  let snapshotQueue = DispatchQueue(label: "snapshot-smoke")
  var pendingSnapshot: SnapshotRequest?
  func enqueueRender(force: Bool, snapshotRequest: SnapshotRequest?) {}
  func pending() -> SnapshotRequest? { snapshotLock.withLock { pendingSnapshot } }
'''+methods+r'''
}

func waitForPending(_ harness: SnapshotHarness, differentFrom prior: SnapshotRequest? = nil) async -> SnapshotRequest {
  for _ in 0..<1000 {
    if let request = harness.pending(), request !== prior { return request }
    try? await Task.sleep(nanoseconds: 1_000_000)
  }
  fatalError("snapshot request was not installed")
}

@main enum Smoke {
  static func main() async {
    // Cancellation can win before withCheckedContinuation installs its handle.
    let preCancelled = SnapshotRequest()
    preCancelled.finish()
    let before = await withCheckedContinuation { continuation in preCancelled.install(continuation) }
    precondition(before == nil && preCancelled.isFinished, "pre-install cancellation")

    let harness = SnapshotHarness()
    let cancelled = Task { await harness.captureSnapshot() }
    let cancelledRequest = await waitForPending(harness)
    cancelled.cancel()
    let cancelledImage = await cancelled.value
    precondition(cancelledImage == nil && cancelledRequest.isFinished && harness.pending() == nil,
                 "post-install cancellation")

    let sample = NSImage(size: NSSize(width: 1, height: 1))
    for _ in 0..<200 {
      let request = SnapshotRequest()
      let ready = DispatchSemaphore(value: 0)
      let task = Task.detached { () -> NSImage? in
        await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            request.install(continuation)
            ready.signal()
          }
        } onCancel: {
          request.finish()
        }
      }
      precondition(ready.wait(timeout: .now() + 2) == .success, "race setup")
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 { task.cancel() } else { request.finish(sample) }
      }
      let image = await task.value
      precondition((image == nil || image === sample) && request.isFinished, "concurrent finish/cancel")
    }

    let first = Task { await harness.captureSnapshot() }
    let firstRequest = await waitForPending(harness)
    let second = Task { await harness.captureSnapshot() }
    let secondRequest = await waitForPending(harness, differentFrom: firstRequest)
    let firstImage = await first.value
    precondition(firstImage == nil && firstRequest.isFinished, "replaced snapshot did not finish")
    secondRequest.finish(sample)
    let secondImage = await second.value
    precondition(secondImage === sample && secondRequest.isFinished, "replacement result lost")
    print("PASS: production snapshot cancellation before/after install, 200 finish races, and replacement")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-snapshot-cancel-') as directory:
    path = Path(directory)
    (path/'test.swift').write_text(fixture)
    cache = path/'module-cache'
    cache.mkdir()
    env = {**os.environ, 'CLANG_MODULE_CACHE_PATH': str(cache), 'SWIFT_MODULE_CACHE_PATH': str(cache)}
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(cache), str(path/'test.swift'), '-o', str(path/'test')], check=True, env=env)
    subprocess.run([str(path/'test')], check=True, timeout=25)
