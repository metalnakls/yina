# Playback UI and HDR

The pause/seek OSD, floating and docked controls, time preview, buffering status,
information overlays and playback sidebars share the current playback window's
HDR/display headroom. Moving to an SDR display or disabling HDR restores SDR
colors and layer formats. Standalone Settings and system menus remain native.

Colors retain their semantic hue, alpha and light/dark appearance; HDR exposure
is applied to those colors rather than substituting different whites for every
control. Watched progress stays white. Native button tracking and slider-thumb
geometry are unchanged. Sidebar cells retain their original colors when reused
or when HDR is disabled. Material rebuilds retain the current dynamic range.

Implementation uses Apple's [NSColor HDR exposure](https://developer.apple.com/documentation/appkit/nscolor),
[CALayer.preferredDynamicRange](https://developer.apple.com/documentation/quartzcore/calayer/preferreddynamicrange)
and [contentsHeadroom](https://developer.apple.com/documentation/quartzcore/calayer/contentsheadroom).
Layer HDR tags alone do not brighten an SDR source color. Overlay content is
above its native glass material to retain its HDR values.

`python3 other/tests/playback-ui-hdr-smoke.py` checks actual AppKit colors in four
appearances, extended-range values, alpha, SDR restoration, recycled-cell colors,
and layer configuration across both material styles. A real HDR display is still
needed to judge perceived brightness and the native glass compositor.
