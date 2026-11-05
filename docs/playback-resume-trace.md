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
