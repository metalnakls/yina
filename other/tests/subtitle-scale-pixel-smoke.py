#!/usr/bin/env python3
"""Render generated SRT pixels with bundled mpv; no installed app or personal media."""
from pathlib import Path
import re
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yina-subtitle-pixel-") as directory:
    root = Path(directory)
    media = root / "black.mkv"
    subtitle = root / "caption.srt"
    binary = root / "probe"
    subtitle.write_text("1\n00:00:00,000 --> 00:00:03,000\nSAME SIZE\n")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=black:size=1280x720:rate=24:duration=3", "-c:v", "ffv1", "-y",
                    str(media)], check=True)
    subprocess.run(["cc", "-I", str(repo / "deps/include"),
                    str(repo / "other/tests/subtitle-scale-pixel-smoke.c"),
                    str(repo / "deps/lib/libmpv.2.dylib"),
                    "-Wl,-rpath," + str(repo / "deps/lib"), "-o", str(binary)], check=True)

    def rows(by_window: str, with_window: str) -> tuple[int, int]:
        output = subprocess.check_output([str(binary), str(media), str(subtitle),
                                          by_window, with_window], text=True, timeout=30)
        match = re.search(r"rows720=(\d+) rows900=(\d+)", output)
        assert match, output
        return int(match.group(1)), int(match.group(2))

    # Both targets display the same 1280x720 picture. The 900-line target adds
    # black bars, so its subtitle glyphs should retain the same screen size.
    corrected = rows("yes", "no")
    video_based = rows("no", "yes")
    legacy = rows("yes", "yes")
    assert corrected[0] > 15 and abs(corrected[0] - corrected[1]) <= 1, corrected
    assert video_based[0] > 15 and abs(video_based[0] - video_based[1]) <= 1, video_based
    assert legacy[1] >= legacy[0] + 5, legacy
    print(f"PASS: same picture rect keeps subtitle glyph height {corrected} / {video_based}; "
          f"legacy window scaling drifts {legacy}")
