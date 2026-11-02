# Recovering NAS playback

A network read failure retains the current player window, media URL, last actual playback position and native playlist. The existing buffering overlay shows **Reconnecting… / Playback paused**. YINA retries every five seconds, with one attempt in flight. Pressing Play while waiting requests an immediate retry. A successful reconnect stays paused at the saved position; press Play to continue. Stop, Close, Quit, opening another file and manual playlist navigation cancel recovery.

Mounted NAS files use the remote-volume classification cached during media preparation. Same-folder playlist entries retain that classification. Other playlist entries are classified on a utility queue; the UI never stats the share to decide whether to show the spinner. Ordinary cache buffering now also updates for NAS files.

The engine reports transport/loading failures separately from normal completion. Those failures, and an EOF more than two seconds before a known duration, can start recovery. Unknown-format and audio/video-output initialization failures retain their existing error behavior. The premature-EOF check is skipped while seeking or initially starting a file; it is a heuristic for demuxers that report a disconnected source as EOF. An inaccurate duration can therefore affect that classification.

An [`on_after_end_file` hook](https://mpv.io/manual/stable/#hooks) drains the failure before mpv advances the playlist. `playlist-play-index none` stops the engine's cursor without clearing the playlist. Retries locate the same entry ID and use [`playlist-play-index`](https://mpv.io/manual/stable/#playlist-manipulation) to reopen it. File-local start/track options and a final exact seek restore the session without changing the next file's start position. Generation checks discard callbacks after cancellation or a newer attempt. Engine requests use the existing asynchronous bridge.

A separate **Resuming…** spinner appears if a Play request has not advanced the playback clock after 250 ms. A pause notification alone does not count as progress. Actual playback movement, Pause, Close or a new media request clears it; connection recovery takes priority over this indicator.

## Checks

- `python3 other/tests/remote-playback-recovery-smoke.py`: production recovery methods, hooks, end-file dispatch and idle handler against real libmpv and a generated seekable stream. The stream returns read errors while offline and rejects reopen attempts, then becomes available again. Checks cover window retention, failed retries, paused restoration, position, playlist order, cancellation and the delayed resume indicator.
- `python3 other/tests/buffer-indicator-state-smoke.py`: production indicator methods with AppKit controls, including reconnect/Play/cache/seek transitions and preference-independent waiting feedback.
- Existing checkpoint/crash-recovery and media-preparation tests continue to cover the ten-second checkpoint policy, SIGKILL resume, and cancellation of old media opens.

The test stream does not reproduce SMB kernel reconnect behavior, an unmounted volume reappearing at a different mount path, or rendered-frame retention through an actual NAS outage. Live sleep/disconnect/reconnect on the user's NAS remains unverified.

The listed checks passed, along with media-preparation, checkpoint policy, fresh-process crash recovery and existing wake/HDR checks. The final local Nightly build passed `other/build_install_nightly.sh`, signature/bundle verification and installation in `/Applications/yina.app`.
