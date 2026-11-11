# Watch Together over the local network

Opening a file in an enabled shared show advertises an ephemeral YINA room over Bonjour (`_yina-watch._tcp`). **Enable for This Show** creates or reuses the `.yina/show.json` identity and starts hosting the current file. No other Mac needs to scan the SMB share to see the live room. The Welcome window shows the nearby Mac and movie; clicking its room explicitly joins it. **File → Shared Show** also lists nearby rooms.

The host and guests exchange bounded, versioned messages over a direct local TCP connection. Messages contain the room ID, show ID, mount-relative folder hint, show-relative media path, position, play/pause and speed. They never contain SMB credentials or absolute host paths. The host accepts commands only from joined peers for its active room, deduplicates command IDs, validates their current revision and path, and broadcasts an authoritative revision. Guests ignore older revisions. Local volume and subtitle choices never travel over the room.

Joining opens the advertised episode only after the user clicks. YINA looks for a locally mounted folder with the matching show ID, then validates the exact relative file inside that folder and checks managed download completeness. A different mount point on each Mac is supported. If automatic matching fails, YINA offers a one-time folder chooser. No network peer can supply an absolute file path or make YINA browse a URL.

Either Mac can pause, resume, seek, change playback speed or switch to another episode in the same show. A guest's local transport action remains in the room; it is sent to the host, which applies and rebroadcasts the result. Explicit episode switches are separate from transport commands, so a delayed pause cannot reopen an old episode. The host's natural end of file leaves the room waiting for the next episode. Explicit stop, leave, player retirement and app quit end the room. If the host disappears, guests disconnect and keep the file already open; they do not replay it or send queued commands to a later room.

The shared `.yina` folder remains the portable identity and progress archive. YINA checkpoints each player's latest position on utility queues and starts a final save before closing windows. Quit gives a healthy share up to two seconds to finish that save, then proceeds even if SMB is stalled. Transfer inventory and download requests keep their existing Glass workflow. Live presence and transport do not use progress or queue file polling.

## Version 6 timing

Both Macs need YINA 6. Playback uses the host's monotonic clock, calibrated by
four-timestamp round trips over the existing persistent TCP connection. Clock
calibration is independent of the Macs' date/time settings. High-latency samples
are filtered, and a provisional one-way clock estimate is not sufficient to
release a readiness barrier.

Explicit controls travel separately from periodic snapshots and archive writes.
The host orders commands and acknowledges their outcome; command IDs prevent a
retry from applying an action twice. Snapshots may be coalesced under pressure,
but controls and readiness reports are retained in order or the connection fails
visibly.

A seek or buffering participant holds the room paused. Readiness belongs to a
specific barrier generation and comes from the playback engine, not from a
queued command. When all joined participants are ready, the host announces a
future start time. A newer pause or seek cancels an older scheduled start.

During continuous playback, small timeline differences are corrected through
bounded playback-rate adjustments. Routine snapshots do not seek. Explicit
seeks and initial positioning still require the engines to seek to the requested
media position. Cache preparation and progress storage remain asynchronous and
cannot gate transmission of a pause command.

This coordinates media timelines, not physical display scanout or audio sample
clocks. Two independent Macs can have different display refresh phases, speaker
latencies, and audio-device buffering. Neither matching engine positions nor a
successful network test establishes frame-locked or sample-locked output.

## Local verification

`other/tests/shared-show-session-mpv-smoke.py` generates two short video files and runs two independent YINA session harness processes with real libmpv engines. The host and guest communicate over Bonjour and exercise both directions of transport, an episode change and host departure. The fixture uses disposable local files and does not write to a real SMB share.

The version 6 fixture also injects a cache-stall observation at the playback
adapter boundary and checks both engines pause, an explicit pause survives
buffer recovery, scheduled playback resumes, and the seek count stays unchanged
during buffer-only recovery. This is not a physical NAS starvation test.

`shared-show-clock-smoke.py` checks clock calibration and uncertainty;
`shared-show-lan-smoke.py` checks real Bonjour/TCP, ordered acknowledgements,
urgent pause, clock-quality gating, and simulated oscillator drift.
`shared-show-sync-invariants-smoke.py` checks stale generations, cancellation,
archive-queue isolation, ordinary playback, join holds, and correction-rate
restoration. Tests with null video/audio outputs do not measure display or
speaker synchronization on two physical Macs.
