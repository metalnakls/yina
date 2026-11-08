# Picture in Picture window lifecycle

Entering PiP from full screen keeps YINA's original full screen window in its native Space. The video view moves into the system PiP window and returns to that same full screen host when PiP closes. YINA no longer exits and recreates a full screen Space for this transition. Its original host controls hide immediately while PiP owns the transport controls.

For a windowed host, the existing PiP preference still chooses whether to keep the window visible, hide it, or minimize it. An already minimized window stays minimized. The pause-on-PiP preference remains independent of that window action. Closing PiP activates the app only when restoring a hidden, minimized, or full screen host; a visible windowed host is left in place.

The system PiP controller retains ownership of its own window placement and chrome timing. YINA uses the original host as the native replacement window and does not move either window between Spaces. The entry policy is covered by a standalone test. Actual cross-Space return animation and system control auto-hide timing remain unverified in a signed app runtime.

The Objective-C bridge declares `PIPViewController.init` as a designated initializer. The system implementation bypasses `NSViewController.init(nibName:bundle:)`; without this declaration, Swift inherits the Objective-C path without initializing `VideoPIPViewController`'s stored properties. Its window-observer array then has null storage and crashes on the first host layout. `python3 other/tests/pip-layout-smoke.py` exercises the production default initializer and layout against the system PiP framework, including observer replacement, cleanup and reentry.

Paused PiP return keeps the last Metal drawable fitted while the view changes size. A frame-change notification can request rendering before Core Animation updates `drawableSize`, so the Metal layer requests a new frame after each drawable-size change as well. This prevents the paused PiP-sized drawable from filling and cropping the returned window until Play is pressed. `python3 other/tests/paused-metal-resize-smoke.py` uses the production layer and libmpv with generated media to reproduce that ordering and check presented dimensions, letterbox pixels, backing-scale changes and continued pause. It requires local GPU access.

## Temporary automatic entry trace

The full-screen entry-flash investigation records four seconds on every PiP entry,
without enabling Advanced logging or screen recording. Captures are JSON Lines at
`~/Library/Logs/tsmc.yina/PiPTransitions/pip-*.jsonl`; the latest 40 are retained.
Each capture includes a wall-clock start and monotonic event offsets, window/Space
and occlusion notifications, 60 Hz main-thread window/layer/HDR snapshots, explicit
backdrop reveal boundaries, requested color-rendering options, and Metal acquire,
presentation, and render timing. A delayed tick exposes a main-thread stall.
The trace does not record screen pixels, video frames, media paths, or subtitles.
It establishes transition timing/state, not proof of visible compositor output.

Records are capped at 4,096 per entry and written in batches on a utility queue.
The timer, observers, and render hooks are detached after four seconds. Reentry
ends the preceding capture before starting another. Normal playback has no trace
sampling or file writes. `python3 other/tests/pip-trace-smoke.py` verifies automatic
shutdown, concurrent callbacks, JSON persistence, visibility data, and retention.
This diagnostic should be removed once the flash is identified and fixed.

The November 8 entry-stutter capture continued rendering with stable HDR state.
Its backdrop became visible about 16 ms after entry, before the video host changed
at roughly 137 ms. Full-window backdrop compositing during the handoff is a
candidate, not a confirmed root cause. The serial render queue is another
candidate: previous logging measured completed renders, not time waiting in it.
The expanded trace records enqueue-to-dequeue delay, render lock/update time,
mpv next-frame flags/target time, render begin/end, and display-link timestamps.
A single outstanding asynchronous mpv query samples pause/cache/position/drop
state every quarter-second; it never blocks the UI or accumulates polling work.
Subtitle-session and Live Text entry boundaries distinguish preparation cost
from the system presentation call. No transition behavior is changed by this
instrumentation, and no visual-stutter fix is claimed.
