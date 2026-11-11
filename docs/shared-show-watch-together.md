# Watch Together over the local network

Opening a file in an enabled shared show advertises an ephemeral YINA room over Bonjour (`_yina-watch._tcp`). **Enable for This Show** creates or reuses the `.yina/show.json` identity and starts hosting the current file. No other Mac needs to scan the SMB share to see the live room. The Welcome window shows the nearby Mac and movie; clicking its room explicitly joins it. **File → Shared Show** also lists nearby rooms.

The host and guests exchange bounded, versioned messages over a direct local TCP connection. Messages contain the room ID, show ID, mount-relative folder hint, show-relative media path, position, play/pause and speed. They never contain SMB credentials or absolute host paths. The host accepts commands only from joined peers for its active room, deduplicates command IDs, validates their current revision and path, and broadcasts an authoritative revision. Guests ignore older revisions. Local volume and subtitle choices never travel over the room.

Joining opens the advertised episode only after the user clicks. YINA looks for a locally mounted folder with the matching show ID, then validates the exact relative file inside that folder and checks managed download completeness. A different mount point on each Mac is supported. If automatic matching fails, YINA offers a one-time folder chooser. No network peer can supply an absolute file path or make YINA browse a URL.

Either Mac can pause, resume, seek, change playback speed or switch to another episode in the same show. A guest's local transport action remains in the room; it is sent to the host, which applies and rebroadcasts the result. Explicit episode switches are separate from transport commands, so a delayed pause cannot reopen an old episode. The host's natural end of file leaves the room waiting for the next episode. Explicit stop, leave, player retirement and app quit end the room. If the host disappears, guests disconnect and keep the file already open; they do not replay it or send queued commands to a later room.

The shared `.yina` folder remains the portable identity and progress archive. YINA checkpoints each player's latest position on utility queues and starts a final save before closing windows. Quit gives a healthy share up to two seconds to finish that save, then proceeds even if SMB is stalled. Transfer inventory and download requests keep their existing Glass workflow. Live presence and transport do not use progress or queue file polling.

## Local verification

`other/tests/shared-show-session-mpv-smoke.py` generates two short video files and runs two independent YINA session harness processes with real libmpv engines. The host and guest communicate over Bonjour and exercise both directions of transport, an episode change and host departure. The fixture uses disposable local files and does not write to a real SMB share.
