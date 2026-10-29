# Unified playback settings

Command-comma and the player's Settings button open one native floating panel.
The panel has Video, Audio, and Subtitles sections rather than a preferences
sidebar. The old Command-Shift-V/A/S bindings are retired, including saved
bindings for those old commands. Key Bindings and Plugins keep their own windows.

Video contains image adjustments; its menu contains tracks and crop. Audio
contains Bass, Mid, and Treble, grouped over the existing ten-band equalizer so
changing one group preserves the others. Its menu contains tracks, output, and
external audio. Subtitles presents the existing named styles as visual samples,
plus Embedded, visibility, track selection, external subtitles, and override
level. Speed and synchronization delays are absent from this panel. Track
selection uses the existing language-pairing behavior, including manual choices.

AppKit owns the panel's size, titlebar, fullscreen auxiliary behavior, and one
native glass surface. SwiftUI supplies standard sliders, menus, buttons, and
scrolling. The hosting view uses `sizingOptions = []`, and numeric labels reserve
their widest value, so changes cannot feed back into window dimensions. No mpv
queries, filesystem reads, preview rendering, or timers run during SwiftUI layout.
See [Apple's hosting-view sizing options](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions).

Run the isolated panel regression without opening media or user settings:

```sh
xcrun swiftc -parse-as-library -module-cache-path /tmp/yina-settings-modules \
  yina/PlaybackSettingsView.swift other/tests/playback-settings-smoke.swift \
  -o /tmp/yina-settings-smoke
/tmp/yina-settings-smoke
```

It exercises real NSPanel/NSHostingView geometry at 400, 600, and 800 points,
repeated slider/style changes, window moves, native scroll preservation, empty
state, EQ group preservation, and delayed playback notifications. Offscreen
captures do not verify the live glass compositor, fullscreen Spaces, keyboard
focus, or VoiceOver. Those still need an installed-app check.
