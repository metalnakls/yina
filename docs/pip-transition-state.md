# PiP transition ownership

`PiPTransitionState` owns desired entry, native phase, session generation, and
source-window restoration policy. `MainWindowController` performs AppKit effects
only after an accepted transition. The public `pipStatus` is a read-only
compatibility projection for existing UI and subtitle observers.

Phases are windowed, waiting for video, entering, active and exiting. A pending
media-open intent can coexist with an exiting session. Completing that session
leaves the intent waiting rather than briefly restoring the source window.

Each native presentation receives a fresh `VideoPIPViewController` tagged with
its generation and current video aspect ratio. Native actions, layout callbacks,
will-close and did-close must come from that controller and an accepted session.
Duplicate completion and callbacks from an older controller are ignored before
reattachment, subtitle cleanup or window restoration. The old delegate is cleared.

Entry waits for playback readiness and a stable fullscreen state. URL/CLI PiP
options record presentation intent after reserving the media open; they no longer
attach PiP to whichever old window happened to be available. The playback owner
consumes pending source-window presentation when PiP owns it. A second user toggle
cancels waiting intent. Failed/canceled loads and explicit stop clear pending
intent; an internal stop for an already queued replacement preserves it.

The backdrop is revealed only after the video is attached outside the source
window. Final close clears the backdrop and consumes pendingShow even if AppKit
omits will-close. A restoring close also shows a source window that has never
been shown; non-restoring close and source-window close do not resurrect it.
The native PiP transition animation and fullscreen Space policy remain in use.

Repeated unchanged native layouts no longer request redraws or resubscribe to
window notifications. Host/geometry changes still refresh subtitles and redraw
paused video. Observer cleanup also runs on controller destruction.

System PiP is a remote presentation host: its AppKit window can report occluded
while actually visible. The Metal visibility guard explicitly accepts that host
while the session owns it. Do not replace the real-system-PiP regression fixture
with an ordinary NSWindow reparenting test.

## Focused checks

- `pip-transition-state-smoke.swift`: pending intent/cancellation, attachment,
  duplicate and stale callbacks, close during entry, missing will-close,
  no-restore policy, reentry during dismissal and media replacement.
- `pip-layout-smoke.py`: actual native controller initialization, factory session
  identity/delegate cleanup/portrait ratio, host replacement, observer lifecycle,
  unchanged-layout redraw suppression and real system PiP presentation.
- `pip-backdrop-smoke.py`: production helpers with real AppKit windows, nil-host
  handoff, backdrop sequencing, waiting-toggle cancellation, never-shown source
  restoration and non-restoring close.
- `paused-metal-resize-smoke.py`: production Metal rendering with generated media,
  including actual system PiP frame presentation despite occlusion=8192.
- Existing PiP subtitle session/geometry and fullscreen entry-plan fixtures remain
  relevant. Short fixtures do not prove the rare compositor stutter is eliminated;
  automatic transition tracing remains enabled.

## Signed-app check

The final signed app passed `YINA_RUN_APP_SMOKE=1 python3
other/tests/pip-app-startup-smoke.py`: an isolated generated-video process opened
via `--pip`, released its own startup pause without a test-issued resume, selected
`videotoolbox`, and recorded 52 positive drawable presentations in the actual
system PiP host. Every sampled source-window state remained hidden. The fixture
closed only its own process. Trace:
`pip-1794168701929-DEF5C4A1-0D1F-49C2-AE71-B96B0F549280.jsonl`.
