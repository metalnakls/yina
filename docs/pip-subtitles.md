# Subtitles beneath Picture in Picture

For plain text SubRip, WebVTT, and `mov_text` tracks, YINA places a nonactivating AppKit child panel directly beneath the system PiP window. It follows PiP movement, resize, and screen changes. Primary and secondary tracks use separate text fields and retain their logical visibility choices. An empty cue hides the panel immediately.

The panel uses AppKit's preferred `.title2` font size as its screen-point reference. The user's mpv font size scales it relative to YINA's existing default of 55, and the user's subtitle scale multiplies it. Font size stays fixed while PiP is resized. Text color, outline, shadow, bold, italic, spacing, horizontal alignment, and margin preferences are applied when AppKit can represent them.

After the panel is ready, YINA asks mpv to suppress the same subtitle track inside the video and reveals the panel only after asynchronous confirmation. On PiP exit it requests the latest logical visibility and retries a failed restore up to three times with short backoff. If the engine rejects every attempt, visibility remains unconfirmed until a later session or user action. Image and styled tracks, unsupported appearance settings, unavailable host windows, occlusion, and PiP positions without room below use mpv's native subtitle renderer. AppKit text styling is approximate; custom ASS layout and bitmap subtitles remain native.

The geometry and suppression lifecycle are covered by standalone tests, including failed restore and rapid reentry cases. Signed-app visual appearance and system PiP window behavior have not yet been checked at runtime.
