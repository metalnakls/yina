import pathlib,subprocess,tempfile
s=pathlib.Path('yina/MainWindowController.swift').read_text(); a=s.index('  private func setWindowAspectRatio(');b=s.index('\n  /// Calculate the window frame',a)
method=s[a:b].replace('private func','func',1)
code='''import Cocoa
enum Preference { static var unlockWindowAspectRatio = false }
class Probe { var window:NSWindow?\n'''+method+'''}
NSApplication.shared.setActivationPolicy(.prohibited)
let probe=Probe();probe.window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:360),styleMask:[.titled,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
for unlocked in [false,true] {
 Preference.unlockWindowAspectRatio=unlocked
 for size in [NSSize(width:1920,height:1080),NSSize(width:1080,height:1920),NSSize(width:2390,height:1000)] {
  probe.setWindowAspectRatio(size)
  if probe.window!.aspectRatio != size {print("FAIL: stored layout setting unlocks video aspect ratio");exit(1)}
 }
}
print("PASS: native aspect lock follows every video regardless of legacy layout setting")
'''
with tempfile.TemporaryDirectory(prefix='yina-aspect-') as d:
 p=pathlib.Path(d)/'main.swift';p.write_text(code);binary=pathlib.Path(d)/'probe'
 subprocess.run(['xcrun','swiftc','-module-cache-path','/private/tmp/yina-event-module-cache',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
