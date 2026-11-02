#!/usr/bin/env python3
"""Exercise production recovery, idle handling and hooks with real libmpv I/O faults."""
from pathlib import Path
import subprocess
import tempfile
import wave

repo = Path(__file__).resolve().parents[2]
source = (repo / 'yina/PlayerCore.swift').read_text()
def method(signature):
    a = source.index('  ' + signature)
    return source[a:source.index('\n  }', a) + 4]
helper = source[source.index('struct RemotePlaybackRecovery {'):source.index('\nclass PlayerCore:')]
methods = '\n'.join(method(s) for s in [
    'func fileEnded(', 'func idleActiveChanged(', 'func updateObservedPlayback(',
    'private func cancelRemotePlaybackRecovery(', 'private func beginRemotePlaybackRecovery(',
    'private func addRemotePlaybackRecoveryHooks(', 'private func scheduleRemoteRecoveryRetry(',
    'private func retryRemotePlayback(', 'private func finishRemotePlaybackRecovery(',
    'private func cancelPlaybackResumeWait(', 'private func startPlaybackResumeWait('])
controller = (repo / 'yina/MPVController.swift').read_text()
a = controller.index('    case MPV_EVENT_END_FILE:')
end_event = controller[a:controller.index('\n    case MPV_EVENT_COMMAND_REPLY:', a)]
fixture = (repo / 'other/tests/remote-playback-recovery-smoke.swift').read_text()
fixture = fixture.replace('// RECOVERY_HELPER', helper).replace('// PRODUCTION_METHODS', methods)
fixture = fixture.replace('// END_EVENT', end_event)
with tempfile.TemporaryDirectory(prefix='yina-remote-recovery-') as d:
    d = Path(d)
    audio = d / 'generated.wav'
    with wave.open(str(audio), 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(8000)
        f.writeframes(bytes(30 * 8000 * 2))
    header = d / 'mpv.h'
    header.write_text('#include <mpv/client.h>\n#include <mpv/stream_cb.h>\n')
    swift = d / 'fixture.swift'; swift.write_text(fixture)
    binary = d / 'recovery'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', '/private/tmp/yina-event-module-cache',
        '-I', str(repo / 'deps/include'), '-import-objc-header', str(header),
        str(repo / 'yina/PlayerState.swift'), str(repo / 'yina/MPVNode.swift'),
        str(repo / 'yina/MPVAsyncClient.swift'), str(repo / 'yina/MPVHook.swift'), str(swift),
        str(repo / 'deps/lib/libmpv.2.dylib'), '-Xlinker', '-rpath', '-Xlinker', str(repo / 'deps/lib'),
        '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(audio)], check=True, timeout=30)
