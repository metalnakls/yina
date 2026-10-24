#!/usr/bin/env python3
"""Exercise the actual intro open handoff with blocked file workers and rapid clicks."""
import os,pathlib,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
welcome=(repo/'yina/InitialWindowController.swift').read_text()
a=welcome.index('  private func openMedia(');b=welcome.index('\n  private func selectRecentDocument',a)
open_method=welcome[a:b].replace('private func','func',1)
a=welcome.index('  private let mediaOpenQueue:');b=welcome.index('\n  private var openRequestGeneration',a)
queue=welcome[a:b]
player=(repo/'yina/PlayerCore.swift').read_text();a=player.index('  struct PreparedWelcomeMedia');b=player.index('\n  func openPreparedWelcomeMedia',a)
prepare=player[a:b]
with tempfile.TemporaryDirectory(prefix='yina-slow-fixture-') as directory:
    root=pathlib.Path(directory);media=root/'media';media.mkdir()
    for i in range(3):(media/f'episode-{i}.mp4').write_bytes(b'synthetic')
    code='''import Cocoa
@_silgen_name("welcome_io_begin") func begin()
@_silgen_name("welcome_io_end") func end()->Int32
let gate=DispatchSemaphore(value:0)
let lock=NSLock();var entered=0
class Utility {
 static let playlistFileExt=["m3u","m3u8"]
 static func resolveURLs(_ urls:[URL])->[URL] {
  precondition(!Thread.isMainThread,"Alias/file work reached the UI thread")
  _=FileManager.default.fileExists(atPath:urls[0].path)
  if urls[0].lastPathComponent != "episode-2.mp4" {
   lock.lock();entered += 1;lock.unlock();gate.wait()
  }
  return urls
 }
}
class FakePlayer {
 var opened:[URL]=[]
 func isBDFolder(_ url:URL)->Bool {false}
 func getPlayableFiles(in urls:[URL])->[URL]{urls}
'''+prepare+'''
 func openPreparedWelcomeMedia(_ media:PreparedWelcomeMedia) {
  precondition(Thread.isMainThread);opened.append(media.urls[0])
 }
}
class FakeWindow {var isVisible=true}
class Probe {
 var player:FakePlayer! = FakePlayer()
 var window:FakeWindow? = FakeWindow()
 var openRequestGeneration=0
'''+queue+'\n'+open_method+'''
}
let probe=Probe();let root=CommandLine.arguments[1]
let urls=(0..<3).map{URL(fileURLWithPath:root+"/episode-"+String($0)+".mp4",isDirectory:false)}
func waitFor(_ condition:()->Bool) {
 let deadline=Date(timeIntervalSinceNow:3)
 while !condition() && Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))}
 precondition(condition(),"Worker/result did not arrive")
}
begin()
probe.openMedia(urls[0]);waitFor{lock.lock();defer{lock.unlock()};return entered==1}
probe.openMedia(urls[1]);waitFor{lock.lock();defer{lock.unlock()};return entered==2}
var ticks=0
let timer=Timer.scheduledTimer(withTimeInterval:0.01,repeats:true){_ in ticks += 1}
let start=Date()
for _ in 0..<20 {probe.openMedia(urls[2])}
let clickTime=Date().timeIntervalSince(start)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.12))
precondition(ticks>=5,"Intro stopped processing events while workers were blocked")
precondition(clickTime<0.05,"Rapid clicks waited for filesystem work")
gate.signal();gate.signal()
waitFor{!probe.player.opened.isEmpty}
precondition(probe.player.opened==[urls[2]],"Canceled/older clicks opened the wrong file")
timer.invalidate()
let calls=end()
precondition(calls==0,"Opening performed media I/O on main")
print(String(format:"PASS: 20 clicks in %.3f seconds, %d UI ticks during blocked I/O, only latest file opened",clickTime,ticks))
'''
    swift=root/'main.swift';swift.write_text(code)
    dylib=root/'delay.dylib';binary=root/'probe'
    subprocess.run(['xcrun','clang','-dynamiclib',str(repo/'other/tests/welcome-ui-io-interpose.c'),'-o',str(dylib)],check=True)
    subprocess.run(['xcrun','swiftc','-module-cache-path','/private/tmp/yina-event-module-cache',str(swift),str(dylib),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(media)],env={**os.environ,'DYLD_INSERT_LIBRARIES':str(dylib)},check=True,timeout=15)
