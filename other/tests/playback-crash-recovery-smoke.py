#!/usr/bin/env python3
"""Kill a generated-media player, then verify native mpv resume in a new process."""
import hashlib
import pathlib
import select
import subprocess
import tempfile
import time
import wave

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "yina/PlayerCore.swift").read_text()

def method(signature):
    start = source.index("  " + signature)
    end = source.index("\n  }", start) + len("\n  }")
    return source[start:end]

methods = method("func updateObservedPlayback(")
helper = ""
if "struct PlaybackPositionCheckpoint {" in source:
    helper = source[source.index("struct PlaybackPositionCheckpoint {"):source.index("\nclass PlayerCore:")]
    methods += "\n" + method("func checkpointPlaybackPosition(")
    methods += "\n" + method("func clearCompletedPlaybackCheckpoint(")
template = (repo / "other/tests/playback-crash-recovery-smoke.swift").read_text()
template = template.replace("// CHECKPOINT_HELPER", helper)
template = template.replace("// CHECKPOINT_PROPERTY", "var playbackCheckpoint = PlaybackPositionCheckpoint()" if helper else "")
template = template.replace("// PRODUCTION_METHODS", methods)

with tempfile.TemporaryDirectory(prefix="yina-crash-recovery-") as directory:
    root = pathlib.Path(directory)
    fixture = root / "generated.wav"
    with wave.open(str(fixture), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(bytes(30 * 8000 * 2))
    watch_later = root / "watch_later"
    watch_later.mkdir()
    header = root / "mpv.h"
    header.write_text("#include <mpv/client.h>\n")
    swift = root / "worker.swift"
    swift.write_text(template)
    binary = root / "worker"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", "/private/tmp/yina-event-module-cache",
                    "-I", str(repo / "deps/include"), "-import-objc-header", str(header),
                    str(repo / "yina/PlayerState.swift"), str(repo / "yina/MPVNode.swift"),
                    str(repo / "yina/MPVAsyncClient.swift"), str(swift),
                    str(repo / "deps/lib/libmpv.2.dylib"), "-Xlinker", "-rpath", "-Xlinker",
                    str(repo / "deps/lib"), "-o", str(binary)], check=True)
    args = [str(binary), str(fixture), str(watch_later)]
    subprocess.run(args + ["seed"], check=True, timeout=10)
    saved = watch_later / hashlib.md5(str(fixture).encode()).hexdigest().upper()
    assert saved.exists(), "Seeded resume position was not saved"
    worker = subprocess.Popen(args + ["crash"], stdout=subprocess.PIPE, text=True)
    try:
        assert select.select([worker.stdout], [], [], 10)[0], "Player did not become ready"
        assert worker.stdout.readline().strip() == "READY", "Player did not reach the new paused position"
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if saved.exists() and "start=18." in saved.read_text():
                break
            time.sleep(0.01)
    finally:
        worker.kill()
        worker.wait(timeout=5)
    subprocess.run(args + ["verify"], check=True, timeout=10)
