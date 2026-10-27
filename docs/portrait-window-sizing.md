# Portrait window sizing

The reproduced failure was the UI widening a portrait playback window. The video
and Metal surface filled the window, but that window did not match the video.

An isolated clean yina instance opened a generated 360×640 clip in a 640×507
window. Requests for 300×534 and 360×640 retained a width of 640. Removing only
the blur accessory removed that clamp. Its empty view had been initialized with
the window's initial width; changing its width after registration did not remove
the minimum. Initialize it with zero width and let AppKit manage the horizontal
dimension. Use the documented `.bottom` placement and update only height when
metrics change. Apple's [accessory documentation](https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller)
explains which dimension the application owns; its
[placement documentation](https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller/layoutattribute)
lists the supported arrangements.

A second failure came from the floating OSC's preferred width and saved
horizontal/vertical positions using `defaultHigh`. The production OSC fixture
turned a requested 360×640 native window into 566×640. Apple's
[window-size priority documentation](https://developer.apple.com/documentation/appkit/nslayoutconstraint/priority-swift.struct/windowsizestayput)
explains that higher priorities can resize the window. Use native
[`dragThatCannotResizeWindow`](https://developer.apple.com/documentation/appkit/nslayoutconstraint/priority-swift.struct/dragthatcannotresizewindow)
for these preferences; retain required viewport edge constraints.

With both corrections, the real playback view opened at 285×507 and resized to
300×534 and 360×640. All 19 recorded states matched the video aspect within one
point, with video bounds and origin matching the window. Both a vertically
encoded clip and a metadata-rotated clip passed. Generated normal and tiny
landscape clips also retained their aspect. Native progressive blur remained
installed.

The bundled Metal renderer was tested separately by reading generated solid-color
frames: video reached every edge across repeated portrait surface resizes, with
and without rotation metadata. These were software-decoding results. Requesting
VideoToolbox fell back to software in that fixture, so it does not establish
hardware-decoder coverage.

Regression checks, with WindowServer access:

- `python3 other/tests/floating-osc-drag-smoke.py` tests actual window shrinking,
  plus dragging, clamping, and saved-position restoration.
- `python3 other/tests/titlebar-mask-smoke.py` checks the accessory's sizing
  request, native variable blur, and full-window video hosting in both orientations.
- `python3 other/tests/titlebar-mask-smoke.py --source-ref HEAD` can compare the
  fixture to a specified source revision (replace HEAD with the pre-fix revision
  to observe the failure).

Fixed-parent layout tests alone cannot detect ancestor-window resizing. Builds
and collapsed sandbox windows are not evidence of correct playback geometry.
