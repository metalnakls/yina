# Temporary unpause diagnostics

Pause/resume actions automatically start a twelve-second capture in
`~/Library/Logs/tsmc.yina/PlaybackResume/resume-*.jsonl`, independent of normal
logging preferences. The latest 40 files are retained. Repeated inputs remain in
the same capture so the first unsuccessful resume and later successful attempts
can be compared. This is instrumentation, not a claimed fix for failed unpause.

The capture records the input/action, requested pause state and transport
generation, guards such as inactive playback or remote recovery, pause submission
and reply (including superseded replies), mpv's pause event arrival and main-thread
handling, playback restart, display-link startup boundaries, and Metal render and
presentation timing. Existing window/layer snapshots accompany these events.
Every quarter-second, one asynchronous property snapshot asks for pause,
paused-for-cache, core-idle, idle-active, eof-reached, time-pos, speed,
cache-buffering-state and vo-configured. Only one snapshot can be outstanding;
a blocked mpv core cannot accumulate polls. No synchronous mpv query is added.

The capture stops automatically and detaches its observers, timer and render
hook. File writes use the existing diagnostic utility queue; at most 12,288
records are accepted per capture. It records no media paths or screen pixels.
Remove these temporary hooks after the cause is identified and corrected.

`python3 other/tests/pip-trace-smoke.py` checks both four-second PiP and
twelve-second resume capture lifetimes, concurrent callback persistence,
state-sampling callbacks, retention, and stop behavior.

## Captured paused-seek resume failure (2026-11-07)

The captured failure accepted `pause=no` (successful command reply), remained
unpaused with a full cache, and submitted only three frames in twelve seconds.
Live inspection showed a frozen audio clock and more than thirty-six minutes of
cached audio/video without a demuxer underrun. The local evidence is retained in
`/Users/wsb/yina/yina-traces/unpause-20261107`.

The AVFoundation driver kept its private `paused` flag across `reset`. mpv's
`ao_reset()` clears `hw_paused`; the subsequent unpause can call `start()` instead
of `set_pause(false)`. Our `start_on_queue()` rejected that start because the
private flag was still true. The public driver `start()` now clears that stale
flag, matching mpv's contract that it starts a pull driver only while unpaused.
System-notification restarts still use `start_on_queue()` directly and respect a
real pause.

`python3 other/tests/avfoundation-underrun-smoke.py` now exercises the actual
pause → reset → start sequence with the production driver. It failed before the
change at “start after paused reset must resume without another set_pause
callback” and passes with the fix. The older test incorrectly invoked `start()`
while still expecting the driver to remain paused, then explicitly unpaused it,
which hid the missing callback case.
