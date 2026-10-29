#!/usr/bin/env python3
"""Run PlayerCore's production preparation methods against delayed open results.

Run from the repository root: python3 other/tests/media-preparation-smoke.py
The test extracts the four method bodies directly from PlayerCore.swift, so a
behavior change in the app is exercised without keeping a copied algorithm.
"""

from pathlib import Path
import subprocess
import tempfile
import textwrap


def method(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for offset in range(opening, len(source)):
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
            if depth == 0:
                return source[start : offset + 1]
    raise AssertionError(f"unclosed production method: {signature}")


source = Path("yina/PlayerCore.swift").read_text()
welcome_source = Path("yina/InitialWindowController.swift").read_text()
methods = "\n\n".join(
    method(source, signature)
    for signature in (
        "  func beginMediaPreparation(_ url: URL?) -> UInt64 {",
        "  func completeMediaPreparation(_ generation: UInt64) -> Bool {",
        "  func abandonMediaPreparation(_ generation: UInt64) {",
        "  private func invalidateMediaPreparation() {",
    )
)
open_media = method(welcome_source, "  private func openMedia(_ url: URL) {")

fixture = f"""
import Foundation

private enum State {{ case idle, playing, shuttingDown, shutDown }}
private final class Info {{ var state: State = .idle }}
private struct PreparedWelcomeMedia {{ let url: URL }}
private final class FakeWindow {{ var isVisible = true }}

private final class PlayerCore {{
  let info = Info()
  private var mediaPreparationGeneration: UInt64 = 0
  private var mediaPreparationPending = false
  private var preparingURL: URL?
  private var idleRetirement: DispatchWorkItem?
  private(set) var retirementRequests = 0
  private(set) var openedURLs: [URL] = []

  private func scheduleIdleRetirement() {{ retirementRequests += 1 }}
{methods}

  func invalidateForTest() {{ invalidateMediaPreparation() }}
  var reservedURL: URL? {{ preparingURL }}
  var isReserved: Bool {{ mediaPreparationPending }}
  func prepareWelcomeMedia(_ url: URL) -> PreparedWelcomeMedia? {{
    Thread.sleep(forTimeInterval: 0.005)
    return PreparedWelcomeMedia(url: url)
  }}
  func openPreparedWelcomeMedia(_ media: PreparedWelcomeMedia) {{ openedURLs.append(media.url) }}
}}

private final class Welcome {{
  var player: PlayerCore?
  var window: FakeWindow? = FakeWindow()
  var pendingMediaPreparationToken: UInt64?
  var openRequestGeneration: UInt64 = 0
  let mediaOpenQueue = OperationQueue()

  init(player: PlayerCore) {{ self.player = player }}
{open_media}

  func open(_ url: URL) {{ openMedia(url) }}
}}

@main
private enum Smoke {{
  static func main() {{
    let player = PlayerCore()
    let welcomeURL = URL(fileURLWithPath: "/tmp/welcome-A.mkv")
    let directURL = URL(fileURLWithPath: "/tmp/direct-B.mkv")

    // The old welcome I/O completes after a newer direct open. The production
    // completion method must only allow the direct request to open media.
    let welcome = player.beginMediaPreparation(welcomeURL)
    let direct = player.beginMediaPreparation(directURL)
    var results: [String] = []
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {{
      if player.completeMediaPreparation(direct) {{ results.append("direct") }}
    }}
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {{
      if player.completeMediaPreparation(welcome) {{ results.append("welcome") }}
    }}
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && results.isEmpty {{ RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }}
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(results == ["direct"], "stale welcome completion opened media")
    precondition(!player.isReserved && player.reservedURL == nil)

    // A late failure/close callback for A cannot release the newer B ticket.
    let old = player.beginMediaPreparation(welcomeURL)
    let newer = player.beginMediaPreparation(directURL)
    player.abandonMediaPreparation(old)
    precondition(player.isReserved && player.reservedURL == directURL)
    precondition(player.completeMediaPreparation(newer))

    // Closing the welcome window invalidates its own reservation.
    let closing = player.beginMediaPreparation(welcomeURL)
    player.abandonMediaPreparation(closing)
    precondition(!player.completeMediaPreparation(closing))
    precondition(player.retirementRequests == 1)

    // Shutdown guards even an in-flight completion before the stop path
    // invalidates its generation; the invalidation rejects it afterward too.
    let stopping = player.beginMediaPreparation(directURL)
    player.info.state = .shuttingDown
    precondition(!player.completeMediaPreparation(stopping))
    player.invalidateForTest()
    player.info.state = .idle
    precondition(!player.completeMediaPreparation(stopping))

    let stopped = player.beginMediaPreparation(directURL)
    player.info.state = .shutDown
    precondition(!player.completeMediaPreparation(stopped))
    player.invalidateForTest()
    precondition(!player.isReserved && player.reservedURL == nil)

    // Exercise the actual welcome entry point through a real OperationQueue.
    // Hold the main thread until its operation has completed; a weak operation
    // reference in the deferred callback is no longer a valid eligibility test.
    let queuePlayer = PlayerCore()
    let welcomeWindow = Welcome(player: queuePlayer)
    welcomeWindow.open(welcomeURL)
    welcomeWindow.mediaOpenQueue.waitUntilAllOperationsAreFinished()
    let queueDeadline = Date().addingTimeInterval(2)
    while Date() < queueDeadline && queuePlayer.openedURLs.isEmpty {{
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }}
    precondition(queuePlayer.openedURLs == [welcomeURL], "finished operation lost its valid main callback")

    let closedPlayer = PlayerCore()
    let closedWindow = Welcome(player: closedPlayer)
    closedWindow.open(welcomeURL)
    closedWindow.window?.isVisible = false
    closedWindow.mediaOpenQueue.waitUntilAllOperationsAreFinished()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(closedPlayer.openedURLs.isEmpty, "closed window opened prepared media")

    print("PASS: stale welcome/direct result, old failure, close cancellation, shutdown invalidation, finished OperationQueue callback")
  }}
}}
"""

with tempfile.TemporaryDirectory(prefix="yina-media-preparation-") as directory:
    fixture_path = Path(directory) / "Fixture.swift"
    binary_path = Path(directory) / "Fixture"
    fixture_path.write_text(textwrap.dedent(fixture))
    subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", directory,
         str(fixture_path), "-o", str(binary_path)],
        check=True,
    )
    subprocess.run([str(binary_path)], check=True)
