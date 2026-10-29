# Unified playback settings

Command-comma and the player's Settings button open one native floating panel.
Picture and Sound sit side by side above a three-column subtitle style gallery.
All three sections remain in one panel. The old Command-Shift-V/A/S bindings are
retired, including saved
bindings for those old commands. Key Bindings and Plugins keep their own windows.

Picture contains image adjustments; its menu contains tracks and crop. Sound
contains native rotary Bass, Mid, and Treble controls, grouped over the existing
ten-band equalizer so changing one group preserves the others. Its menu contains tracks, output, and
external audio. Subtitles presents the existing named styles as visual samples,
plus Embedded, visibility, track selection, external subtitles, and override
level. Speed and synchronization delays are absent from this panel. Track
selection uses the existing language-pairing behavior, including manual choices.

AppKit owns the panel's bounded size, titlebar, fullscreen auxiliary behavior, and
one native glass surface. The default is 740×740 points, with width restricted to
700–780 points and height to 600–900 points, constrained to the current display.
The wider default and limited resize range are
YINA-specific design choices for this control layout, not Apple spacing rules.
Legacy saved sizes outside that range return to the new default, retaining their
top edge and position where the display allows. Valid resized windows retain
their size. The hosting view also bridges AppKit's effective appearance into
SwiftUI so labels and controls follow light and dark mode together.

SwiftUI supplies standard picture sliders, menus, buttons, and scrolling; the
tone controls wrap AppKit's [circular NSSlider](https://developer.apple.com/documentation/appkit/nsslider/slidertype-swift.enum).
The hosting view uses `sizingOptions = []`, and numeric labels reserve
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

It exercises real NSPanel/NSHostingView geometry at minimum, default, and maximum
widths, legacy frame restoration, repeated normalization, slider/style changes,
window moves, scroll preservation, empty state, EQ group preservation, delayed
playback notifications, rotary keyboard focus and stepping, accessibility
increment actions, and disabled controls. It renders light and dark appearances
at default and minimum sizes. Run with WindowServer access for the real-display
restoration checks. Offscreen captures do not verify the live glass compositor,
fullscreen Spaces, mouse dragging, or spoken VoiceOver output.
