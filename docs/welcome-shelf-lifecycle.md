# Welcome cards after fullscreen entry

The card shelf is a separate native child window above the welcome window. Its visibility previously depended only on `window.isVisible`. During close/Space transitions AppKit can still report the parent visible after `willClose`, and a queued artwork/layout update could order the shelf front again.

The welcome controller now owns an explicit showing/closing state. Close clears it before invoking AppKit. Hiding the shelf sets its alpha to zero, disables mouse events, detaches it from its parent and orders it out. Late updates cannot reattach it; explicitly showing the welcome window permits reattachment. Card geometry, native scrolling and materials stay unchanged.

`python3 other/tests/welcome-shelf-lifecycle-smoke.py` reproduces the closing-window race with real `NSWindow` objects and the production visibility method. It failed before the change and passes afterward, including reopen and empty-shelf transitions. It does not automate a live fullscreen Space transition in the running player.
