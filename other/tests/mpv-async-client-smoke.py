#!/usr/bin/env python3
"""Exercise the production async bridge with libmpv, without launching YINA."""
from pathlib import Path
import os, shutil
import subprocess, tempfile
repo = Path(__file__).resolve().parents[2]
library = Path(os.environ.get('YINA_MPV_TEST_LIB', str(repo/'deps/lib/libmpv.2.dylib')))
source = r'''
import Foundation
import Cocoa
import CoreFoundation

enum YINAError: Error { case unsupportedMPVNodeFormat(UInt32) }
_ = NSApplication.shared
FileHandle.standardError.write(Data("bridge stage: before create\n".utf8))
let handle = mpv_create()!
FileHandle.standardError.write(Data("bridge stage: after create\n".utf8))
mpv_set_option_string(handle, "config", "no")
mpv_set_option_string(handle, "load-scripts", "no")
mpv_set_option_string(handle, "vo", "null")
mpv_set_option_string(handle, "ao", "null")
let initStatus = mpv_initialize(handle)
FileHandle.standardError.write(Data("bridge stage: after initialize \(initStatus)\n".utf8))
precondition(initStatus >= 0, "mpv_initialize returned \(initStatus)")
let client = MPVAsyncClient()
client.activate(handle)
var foreign = mpv_event()
foreign.reply_userdata = 1_000_000
foreign.event_id = MPV_EVENT_COMMAND_REPLY
precondition(!client.consume(foreign), "foreign command reply was consumed")
foreign.event_id = MPV_EVENT_SET_PROPERTY_REPLY
precondition(!client.consume(foreign), "foreign property reply was consumed")
let state = NSLock()
var stopped = false
let events = DispatchGroup()
events.enter()
DispatchQueue.global().async {
  while true {
    state.lock(); let done = stopped; state.unlock()
    if done { break }
    let event = mpv_wait_event(handle, 0.02)!.pointee
    _ = client.consume(event)
  }
  events.leave()
}
func wait(_ condition: () -> Bool) {
  let limit = Date().addingTimeInterval(5)
  while !condition() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  precondition(condition(), "Timed out waiting for async reply")
}
var done = false
client.set("pause", .flag(true)) { error in
  precondition(Thread.isMainThread && error >= 0)
  client.get(["pause", "speed", "property-that-does-not-exist"]) { values in
    precondition(values["pause"] as? Bool == true)
    precondition(values["speed"] as? Double == 1)
    precondition(values["property-that-does-not-exist"] == nil)
    done = true
  }
}
wait { done }
for i in 0..<200 { client.setLatest("speed", .double(1 + Double(i) / 100)) }
var value: Double = 0
let deadline = Date().addingTimeInterval(5)
while value != 2.99 && Date() < deadline {
  done = false
  client.get(["speed"]) { values in value = values["speed"] as? Double ?? 0; done = true }
  wait { done }
}
precondition(value == 2.99, "Latest control value was lost")
for i in 0..<200 { client.setLatest("speed", .double(1 + Double(i) / 100)) }
client.discardLatest(["speed"])
done = false
client.set("speed", .double(1.25)) { error in precondition(error >= 0); done = true }
wait { done }
done = false
client.get(["speed"]) { values in value = values["speed"] as? Double ?? 0; done = true }
wait { done }
precondition(value == 1.25, "Final restore was overwritten by a stale animation frame")
for i in 0..<200 { client.setLatest("speed", .double(1 + Double(i) / 100)) }
for i in 0..<200 { client.commandLatest("equalizer-like", arguments: ["set", "volume", "\(50 + i / 10)"]) }
client.flushLatest()
done = false
client.get(["speed", "volume"]) { values in
  precondition(values["speed"] as? Double == 2.99, "Final coalesced property missed checkpoint")
  precondition(values["volume"] as? Double == 69, "Final coalesced command missed checkpoint")
  done = true
}
wait { done }
done = false
client.command(["set", "pause", "no"]) { error in
  precondition(error >= 0)
  client.get(["pause"], strings: true) { values in
    precondition(values["pause"] as? String == "no")
    done = true
  }
}
wait { done }
var completions = 0
for _ in 0..<20 { client.get(["speed"]) { _ in completions += 1 } }
client.invalidate()
wait { completions == 20 }
done = false
client.set("pause", .flag(true)) { error in precondition(error < 0); done = true }
wait { done }
state.lock(); stopped = true; state.unlock()
events.wait()
mpv_terminate_destroy(handle)
print("PASS: real libmpv typed/string replies, foreign replies, final restore, flush before checkpoint, shutdown cancellation and main-thread completion")
'''
with tempfile.TemporaryDirectory(prefix='yina-async-client-', dir='/private/tmp') as folder:
    root = Path(folder)
    (root/'main.swift').write_text(source)
    (root/'mpv.h').write_text('#include <mpv/client.h>\n')
    binary = root/'probe'
    subprocess.run(['xcrun','swiftc','-module-cache-path','/tmp/yina-async-module-cache',
      '-I',str(repo/'deps/include'),'-import-objc-header',str(root/'mpv.h'),
      str(repo/'yina/MPVNode.swift'),str(repo/'yina/MPVAsyncClient.swift'),str(root/'main.swift'),
      str(library),'-Xlinker','-rpath','-Xlinker',str(library.parent),'-o',str(binary)],check=True)
    if debug_binary := os.environ.get('YINA_MPV_DEBUG_BINARY'):
        shutil.copy2(binary, debug_binary)
    subprocess.run([str(binary)],check=True,timeout=25)
