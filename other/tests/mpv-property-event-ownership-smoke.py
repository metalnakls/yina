#!/usr/bin/env python3
"""Deliver real libmpv property structs after their borrowed values are gone."""

from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
controller = (repo / "yina/MPVController.swift").read_text()
start = controller.index("    // mpv invalidates property.data")
delivery = controller[start:controller.index("\n  }", start)]
fixture = r'''
import Foundation

final class EventController {
  typealias Name = String
  var delivered: [Any] = []
  func hasListener(for name: Name) -> Bool { true }
  func emit(_ name: Name, data: Any) {
    precondition(Thread.isMainThread)
    delivered.append(data)
  }
}

final class Fixture {
  struct Player { let events = EventController() }
  let player = Player()

  func propertyChanged(_ name: String, _ property: mpv_event_property) {
    // PRODUCTION_DELIVERY
  }

  func send<T>(_ format: mpv_format, _ value: T, poison: T) {
    let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
    storage.initialize(to: value)
    propertyChanged("fixture", mpv_event_property(name: nil, format: format, data: storage))
    storage.pointee = poison
    storage.deinitialize(count: 1)
    storage.deallocate()
  }
}

let fixture = Fixture()
fixture.send(MPV_FORMAT_FLAG, Int32(256), poison: 0)
fixture.send(MPV_FORMAT_INT64, Int64(1234567), poison: -1)
fixture.send(MPV_FORMAT_DOUBLE, 6.25, poison: -1)
let string = strdup("copied before delivery")!
fixture.send(MPV_FORMAT_STRING, Optional(UnsafePointer(string)), poison: nil)
memset(string, 0, 22)
free(string)
fixture.send(MPV_FORMAT_STRING, Optional<UnsafePointer<CChar>>.none, poison: nil)
fixture.propertyChanged("fixture", mpv_event_property(name: nil, format: MPV_FORMAT_DOUBLE, data: nil))
fixture.send(MPV_FORMAT_NONE, Int64(42), poison: -1)
precondition(fixture.player.events.delivered.isEmpty)
let deadline = Date().addingTimeInterval(2)
while fixture.player.events.delivered.count < 7 && Date() < deadline {
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
let values = fixture.player.events.delivered
precondition(values.count == 7)
precondition(values[0] as? Bool == true)
precondition(values[1] as? Int64 == 1234567)
precondition(values[2] as? Double == 6.25)
precondition(values[3] as? String == "copied before delivery")
precondition(values[4...6].allSatisfy { $0 is NSNull })
print("PASS: main-queue plugin events own copied C flags, numbers, and strings")
'''.replace("    // PRODUCTION_DELIVERY", delivery)

with tempfile.TemporaryDirectory(prefix="yina-event-payload-") as directory:
    directory = Path(directory)
    source = directory / "main.swift"
    source.write_text(fixture)
    header = directory / "mpv.h"
    header.write_text("#include <mpv/client.h>\n")
    binary = directory / "fixture"
    subprocess.run(
        ["xcrun", "swiftc", "-I", str(repo / "deps/include"),
         "-import-objc-header", str(header), str(source), "-o", str(binary)],
        check=True,
    )
    subprocess.run([str(binary)], check=True, timeout=10)
