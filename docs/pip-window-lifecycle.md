# Picture in Picture window lifecycle

Entering PiP from full screen keeps YINA's original full screen window in its native Space. The video view moves into the system PiP window and returns to that same full screen host when PiP closes. YINA no longer exits and recreates a full screen Space for this transition. Its original host controls hide immediately while PiP owns the transport controls.

For a windowed host, the existing PiP preference still chooses whether to keep the window visible, hide it, or minimize it. An already minimized window stays minimized. The pause-on-PiP preference remains independent of that window action. Closing PiP activates the app only when restoring a hidden, minimized, or full screen host; a visible windowed host is left in place.

The system PiP controller retains ownership of its own window placement and chrome timing. YINA uses the original host as the native replacement window and does not move either window between Spaces. The entry policy is covered by a standalone test. Actual cross-Space return animation and system control auto-hide timing remain unverified in a signed app runtime.

The Objective-C bridge declares `PIPViewController.init` as a designated initializer. The system implementation bypasses `NSViewController.init(nibName:bundle:)`; without this declaration, Swift inherits the Objective-C path without initializing `VideoPIPViewController`'s stored properties. Its window-observer array then has null storage and crashes on the first host layout. `python3 other/tests/pip-layout-smoke.py` exercises the production default initializer and layout against the system PiP framework, including observer replacement, cleanup and reentry.
