#!/usr/bin/env python3
import pathlib,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
source_text = (repo/'yina/OSCFloatingView.swift').read_text()
s=source_text.split('private final class OSCFloatingContentView:')[0]
with tempfile.TemporaryDirectory(prefix='yina-osc-color-') as d:
 d=pathlib.Path(d);source=d/'OSCButton.swift';source.write_text('import Cocoa\n'+s)
 binary=d/'probe'
 subprocess.run(['xcrun','swiftc','-module-cache-path','/private/tmp/yina-event-module-cache',str(source),str(repo/'yina/OSCExtendedDynamicRange.swift'),str(repo/'other/tests/osc-button-color-smoke.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True,timeout=15)
