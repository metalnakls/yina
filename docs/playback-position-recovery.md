# Playback position recovery

Playback progress previously depended on `PlayerCore.savePlaybackPosition()` during stop/quit. The bundled mpv loads and then deletes the previous watch-later file when resuming (`player/loadfile.c`). A crash after that deletion but before the next normal stop could therefore lose both the current session and the previous saved position. History records the media and duration, not a separate durable position.

`PlaybackPositionCheckpoint` now requests native watch-later writes from observed playback progress every ten seconds. This is independent of the OSC timer, so hiding controls or using PiP does not stop checkpointing. Playback restart, completed seeks and pause request an immediate checkpoint. Loading and in-progress seeks cannot checkpoint; unchanged paused positions do not keep writing. Requests are serialized, a pending pause/seek receives a follow-up save, failed submissions get two delayed retries, and file generations reject stale replies. Normal stop still makes the final save.

The bundled mpv writes a temporary file and renames it over the existing watch-later file (`misc/io_utils.c`), preserving the prior checkpoint if a process crashes during a replacement. A crash can still lose progress since the latest completed checkpoint, normally up to about ten seconds. This protects against process crashes, not an assertion that every write has reached hardware during a power failure. Non-seekable streams and advanced configurations excluding `start` retain mpv's existing behavior. Turning off Resume Last Playback Position disables these writes too.

On EOF, the checkpoint is removed for the explicit media path, preventing periodic saving from making a finished episode resume near its end. Seeking back from EOF starts saving again. The welcome screen prefers the native saved position over the older last-closed-file preference. The progress reader accepts filename comments and custom watch-later option ordering instead of requiring `start` on line one.

Verification:

- `python3 other/tests/playback-crash-recovery-smoke.py` uses generated audio and the production observation/checkpoint methods, async bridge and bundled libmpv. It seeds a saved position, resumes and seeks while paused, kills that process with SIGKILL, then verifies native resume in a fresh process. Before the fix it reopened at 0 seconds instead of 18; after the fix it resumes at 18.
- `python3 other/tests/playback-checkpoint-policy-smoke.py` covers cadence, unchanged pause, seek coalescing, submission retry, file generations, disabled resume, loading guards and EOF cleanup.
- `python3 other/tests/watch-later-progress-smoke.py` covers comment headers, reordered options, missing files and invalid progress.
