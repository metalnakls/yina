#!/usr/bin/env python3
"""Run welcome identities/snapshot publishing against delayed synthetic filesystem calls."""
import os,pathlib,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='yina-slow-fixture-') as directory:
    root=pathlib.Path(directory)
    media=root/'media';media.mkdir()
    for index in range(3): (media/f'episode-{index}.mp4').write_bytes(b'test fixture')
    def read_source(path):
        return (repo/path).read_text()
    source=read_source('yina/ShowFolder.swift')
    models=source[:source.index('enum WelcomeRecentSnapshotStore')].replace('UserDefaults','MemoryDefaults')
    welcome=read_source('yina/InitialWindowController.swift')
    a=welcome.index('  private func documentIdentity(');b=welcome.index('\n  private static func isDocumentAvailable',a)
    identity=welcome[a:b].replace('private func','func')
    code='''import Cocoa
@_silgen_name("welcome_io_begin") func begin()
@_silgen_name("welcome_io_end") func end()->Int32
final class MemoryDefaults {
 var values:[String:Any]=[:]
 func set(_ value:Any?,forKey key:String){values[key]=value}
 func stringArray(forKey key:String)->[String]?{values[key] as? [String]}
 func data(forKey key:String)->Data?{values[key] as? Data}
}
enum AppEnvironment { static let defaults=MemoryDefaults() }
class Probe {
'''+identity+'''}
let root=CommandLine.arguments[1]
let folder=URL(fileURLWithPath:root,isDirectory:true)
let shows=(0..<3).map { index in
 ShowFolder(kind:.file,folderURL:folder,primaryTitle:"Fixture",
 resumeURL:URL(string:"file://"+root+"/episode-"+String(index)+".mp4")!,
 secondaryTitle:"Fixture",lastPlayedAt:Date(),position:1,duration:10,thumbnailCacheName:"fixture")
}
let probe=Probe()
begin()
let start=Date()
// These exact model operations run on the UI thread during row/card redraws,
// keyboard selection, artwork publication and snapshot updates.
for _ in 0..<3 {
 for show in shows { _=show.identityPath;_=probe.documentIdentity(show.resumeURL) }
 ShowFolderSnapshotStore.save(shows)
}
let calls=end();let elapsed=Date().timeIntervalSince(start)
print(String(format:"Welcome UI: %d filesystem calls, %.3f seconds",calls,elapsed))
if calls != 0 || elapsed > 0.1 { print("FAIL: intro UI waits for slow-volume filesystem calls");exit(1) }
print("PASS: card/row identities and snapshot publication perform no media filesystem I/O")
'''
    swift=root/'main.swift';swift.write_text(models+'\n'+code)
    dylib=root/'delay.dylib';binary=root/'probe'
    subprocess.run(['xcrun','clang','-dynamiclib',str(repo/'other/tests/welcome-ui-io-interpose.c'),'-o',str(dylib)],check=True)
    subprocess.run(['xcrun','swiftc','-module-cache-path','/private/tmp/yina-event-module-cache',str(swift),str(dylib),'-o',str(binary)],check=True)
    subprocess.run([str(binary),'/private'+str(media) if not str(media).startswith('/private/') else str(media)],env={**os.environ,'DYLD_INSERT_LIBRARIES':str(dylib)},check=True,timeout=20)
